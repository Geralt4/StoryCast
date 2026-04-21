import Foundation
import SwiftUI
import SwiftData
import os
import Combine
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class PlayerViewModel {
    let book: Book
    private(set) var modelContext: ModelContext?

    // MARK: - Observable State

    var coverArtUIImage: UIImage?
    var showMissingFileAlert = false
    var showPlaybackSaveError = false
    var playbackSaveErrorMessage = ""
    var showRemoteServerError = false
    var remoteServerErrorMessage = ""
    private(set) var playbackSettings = PlaybackSettings.load()

    // MARK: - Chapter Playback State

    private(set) var cachedSortedChapters: [Chapter]

    // MARK: - Private State

    private var chapterPlaybackSession: ChapterPlaybackSession?
    private var chapterTransitionLockUntil: Date?
    private var coverArtTask: Task<Void, Never>?
    private var chapterExtractionTask: Task<Void, Never>?
    private var remotePlaybackTask: Task<Void, Never>?
    private var playbackSaveErrorTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var periodicSaveTimer: Timer?
    private var lastSavedPosition: Double = -1.0

    // MARK: - Singleton References

    private let audioPlayer = AudioPlayerService.shared
    private let sleepTimer = SleepTimerService.shared
    private let sessionManager = PlaybackSessionManager.shared

    // MARK: - Private Types

    private struct ChapterBoundary {
        let title: String
        let startTime: Double
        let endTime: Double
    }

    private struct ChapterPlaybackSession {
        var boundaries: [ChapterBoundary]
        var currentIndex: Int
    }

    // MARK: - Init

    init(book: Book) {
        self.book = book
        self.cachedSortedChapters = book.chapters.sorted { $0.startTime < $1.startTime }
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Computed Properties

    var safeDuration: Double {
        guard book.duration.isFinite, book.duration > 0 else {
            return 0
        }
        return book.duration
    }

    var skipBackwardSeconds: Int {
        Int(playbackSettings.skipBackwardSeconds.rounded())
    }

    var skipForwardSeconds: Int {
        Int(playbackSettings.skipForwardSeconds.rounded())
    }

    var skipBackwardSymbol: String {
        skipSymbolName(for: skipBackwardSeconds, baseName: "gobackward")
    }

    var skipForwardSymbol: String {
        skipSymbolName(for: skipForwardSeconds, baseName: "goforward")
    }

    var bookAudioURL: URL? {
        if book.isRemote {
            if book.isDownloaded, let cachePath = book.localCachePath {
                return StorageManager.shared.remoteAudioCacheURL(for: cachePath)
            }
            return nil
        }
        return StorageManager.shared.storyCastLibraryURL.appendingPathComponent(book.localFileName)
    }

    var usesRemoteStreaming: Bool {
        book.isRemote && !book.isDownloaded
    }

    // MARK: - Lifecycle

    func onAppear() {
        audioPlayer.playbackDidReachEnd = false
        refreshPlaybackSettings()
        updateSortedChapters()
        let audioURL = bookAudioURL
        if audioPlayer.isPlaying, isCurrentBookLoaded(expectedURL: audioURL) {
            updateLastPlayedDate()
        }
        if !isCurrentBookLoaded(expectedURL: audioURL) {
            // Cancel sleep timer when switching to a different book
            if sleepTimer.isActive {
                sleepTimer.cancel()
            }

            // Cancel any previous remote playback task
            remotePlaybackTask?.cancel()

            if book.isRemote && !book.isDownloaded {
                // For remote books not downloaded, start a streaming session
                remotePlaybackTask = Task { @MainActor in
                    do {
                        let stream = try await startRemotePlaybackSession()
                        guard !Task.isCancelled else { return }
                        audioPlayer.loadAuthenticatedAudio(stream: stream, title: book.title, duration: safeDuration, seekTo: book.lastPlaybackPosition)
                    } catch APIError.noActiveServer {
                        showRemoteServerError = true
                        remoteServerErrorMessage = "Server not found. Please check your Audiobookshelf server configuration."
                    } catch APIError.tokenMissing {
                        showRemoteServerError = true
                        remoteServerErrorMessage = "Authentication failed. Please log in to your Audiobookshelf server again."
                    } catch APIError.serverUnreachable {
                        showRemoteServerError = true
                        remoteServerErrorMessage = "Server is unreachable. Please check your network connection and try again."
                    } catch {
                        showRemoteServerError = true
                        remoteServerErrorMessage = error.localizedDescription
                    }
                }
            } else {
                // audioURL is always non-nil for local books
                guard let localAudioURL = audioURL else { return }
                Task { @MainActor in
                    let fileExists = await Task.detached(priority: .utility) {
                        FileManager.default.fileExists(atPath: localAudioURL.path)
                    }.value
                    guard audioPlayer.currentURL != localAudioURL else { return }
                    if fileExists {
                        let backupPosition = restorePositionFromUserDefaults()
                        let startPosition = backupPosition ?? book.lastPlaybackPosition
                        audioPlayer.loadAudio(url: localAudioURL, title: book.title, duration: safeDuration, seekTo: startPosition)
                        
                        // If we restored from backup, also update the book's position
                        if let backupPosition = backupPosition {
                            book.lastPlaybackPosition = backupPosition
                            do {
                                try modelContext?.save()
                                clearPositionBackup()
                            } catch {
                                AppLogger.playback.error("Failed to restore backup position: \(error.localizedDescription, privacy: .private)")
                            }
                        }
                    } else {
                        showMissingFileAlert = true
                    }
                }
            }
        }

        // Load cover art asynchronously
        coverArtTask?.cancel()
        coverArtTask = Task { @MainActor in
            await loadCoverArt()
            guard !Task.isCancelled else { return }
            guard isCurrentBookLoaded(expectedURL: audioURL) else { return }
            audioPlayer.updateNowPlayingInfo(title: book.title, duration: safeDuration, currentTime: audioPlayer.currentTime, artwork: coverArtUIImage)
        }

        // Lazy extract embedded chapters if none exist (for local and downloaded books)
        if (!book.isRemote || book.isDownloaded) && book.chapters.isEmpty {
            chapterExtractionTask?.cancel()
            chapterExtractionTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                guard let url = self.bookAudioURL else { return }
                let extractor = MetadataChapterExtractor()
                let detectedChapters = await Task.detached(priority: .utility) {
                    try? await extractor.extractChapters(from: url)
                }.value
                guard !Task.isCancelled else { return }
                if let detectedChapters = detectedChapters, !detectedChapters.isEmpty {
                    for detChapter in detectedChapters {
                        let chapter = Chapter(
                            title: detChapter.title,
                            startTime: detChapter.startTime,
                            endTime: detChapter.endTime,
                            source: detChapter.source,
                            book: book
                        )
                        guard chapter.isValid else {
                            AppLogger.ui.warning("Skipping invalid chapter while loading player data")
                            continue
                        }
                        modelContext?.insert(chapter)
                    }
                    do {
                        try modelContext?.save()
                    } catch {
                        AppLogger.ui.error("Error saving new chapters: \(error.localizedDescription, privacy: .private)")
                    }
                }
            }
        }
        
        // Start periodic save timer for progress safety net
        startPeriodicSaveTimer()
    }

    func onDisappear() {
        coverArtTask?.cancel()
        chapterExtractionTask?.cancel()
        playbackSaveErrorTask?.cancel()
        remotePlaybackTask?.cancel()
        periodicSaveTimer?.invalidate()
        periodicSaveTimer = nil
        clearChapterPlaybackSession()
        // Save playback position only if this book is still loaded
        guard isCurrentBookLoaded() else { return }
        forceSavePlaybackPosition(audioPlayer.currentTime, errorMessage: "Couldn't save playback position.")
        // Close remote session if this was a remote book
        if book.isRemote {
            Task {
                await sessionManager.closeCurrentSession()
            }
        }
    }

    // MARK: - Event Handlers

    func handleCurrentTimeUpdate(_ newValue: Double, isUserDragging: Bool) {
        handleChapterBoundaryIfNeeded(currentTime: newValue, isUserDragging: isUserDragging)
        debouncedSavePlaybackPosition(newValue)
    }

    func handlePlaybackDidReachEnd() {
        clearChapterPlaybackSession()
        audioPlayer.pause()
        persistPlaybackPosition(book.duration, errorMessage: "Couldn't save completed playback position.", forceImmediate: true)
    }

    func handlePlaybackStateChange(isPlaying: Bool) {
        guard isCurrentBookLoaded() else { return }
        if isPlaying {
            updateLastPlayedDate()
            AccessibilityNotifications.announce("Playing \(book.title)")
        } else {
            // Save immediately when pausing to prevent data loss on app close
            forceSavePlaybackPosition(audioPlayer.currentTime, errorMessage: "Couldn't save playback position.")
            AccessibilityNotifications.announce("Paused")
        }
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard newPhase == .inactive || newPhase == .background else { return }
        guard isCurrentBookLoaded() else { return }
        forceSavePlaybackPosition(audioPlayer.currentTime, errorMessage: "Couldn't save playback position.")
    }

    func handleChaptersCountChange() {
        updateSortedChapters()
    }

    func handleUserDefaultsChange() {
        refreshPlaybackSettings()
    }

    // MARK: - Slider

    func syncSliderValue() -> Double {
        let duration = (book.duration.isFinite && book.duration > 0) ? book.duration : 0
        let maxValue = max(duration, MathDefaults.minDurationSafetyValue)
        return min(max(book.lastPlaybackPosition, 0), maxValue)
    }

    // MARK: - Playback Actions

    func skipBackward() {
        HapticManager.impact(.light)
        clearChapterPlaybackSession()
        audioPlayer.skipBackward()
    }

    func togglePlayPause() {
        HapticManager.impact(.medium)
        audioPlayer.togglePlayPause()
    }

    func skipForward() {
        HapticManager.impact(.light)
        clearChapterPlaybackSession()
        audioPlayer.skipForward()
    }

    func handleSliderEditingChanged(_ editing: Bool) {
        if editing {
            HapticManager.selection()
        }
        if !editing {
            clearChapterPlaybackSession()
            audioPlayer.seek(to: sliderValueForSeek)
            persistPlaybackPosition(sliderValueForSeek, errorMessage: "Couldn't save playback position.", forceImmediate: true)
        }
    }

    /// Temporary storage for the slider value passed from the view during seek
    var sliderValueForSeek: Double = 0.0

    // MARK: - Chapter Playback

    func startChapterPlaybackSession(from chapters: [Chapter], selectedIndex: Int) {
        let boundaries = chapters.map {
            ChapterBoundary(title: $0.title, startTime: $0.startTime, endTime: $0.endTime)
        }
        guard boundaries.indices.contains(selectedIndex) else {
            clearChapterPlaybackSession()
            return
        }
        chapterPlaybackSession = ChapterPlaybackSession(boundaries: boundaries, currentIndex: selectedIndex)
        chapterTransitionLockUntil = Date().addingTimeInterval(PlaybackDefaults.timeObserverInterval + 0.25)
    }

    func clearChapterPlaybackSession() {
        chapterPlaybackSession = nil
        chapterTransitionLockUntil = nil
    }

    func chapterAt(time: Double) -> Chapter? {
        binarySearchChapter(at: time)
    }

    // MARK: - Private Helpers

    private func skipSymbolName(for seconds: Int, baseName: String) -> String {
        let supported = PlaybackDefaults.supportedSkipSymbolIntervals
        let nearest = supported.min { abs($0 - seconds) < abs($1 - seconds) } ?? 15
        return "\(baseName).\(nearest)"
    }

    private func refreshPlaybackSettings() {
        playbackSettings = PlaybackSettings.load()
    }

    private func updateLastPlayedDate() {
        book.lastPlayedDate = Date()
        do {
            assertModelContextConfigured()
            try modelContext?.save()
        } catch {
            presentPlaybackSaveError("Couldn't save recently played date.")
        }
    }

    private func isCurrentBookLoaded(expectedURL: URL? = nil) -> Bool {
        if usesRemoteStreaming {
            return sessionManager.isCurrentSession(for: book)
        }
        guard let url = expectedURL ?? bookAudioURL else { return false }
        return audioPlayer.currentURL == url
    }

    private func fetchServer(for serverId: UUID?) -> ABSServer? {
        guard let serverId = serverId else { return nil }
        let descriptor = FetchDescriptor<ABSServer>(
            predicate: #Predicate { $0.id == serverId }
        )
        do {
            return try modelContext?.fetch(descriptor).first
        } catch {
            AppLogger.network.error("Failed to fetch server for remote playback: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func startRemotePlaybackSession() async throws -> AuthenticatedStream {
        guard let server = fetchServer(for: book.serverId) else {
            throw APIError.noActiveServer
        }
        return try await sessionManager.startSession(for: book, server: server)
    }

    private func loadCoverArt() async {
        guard let fileName = book.coverArtFileName else {
            self.coverArtUIImage = nil
            return
        }

        let coverArtURL = StorageManager.shared.coverArtURL(for: fileName, isRemote: book.isRemote)
        let image = await CoverArtCache.shared.image(for: fileName, url: coverArtURL)

        await MainActor.run {
            self.coverArtUIImage = image
        }
    }

    // MARK: - Playback Position Persistence

    func persistPlaybackPosition(_ position: Double, errorMessage: String, forceImmediate: Bool = false) {
        if forceImmediate {
            forceSavePlaybackPosition(position, errorMessage: errorMessage)
        } else {
            debouncedSavePlaybackPosition(position)
        }
    }

    private func debouncedSavePlaybackPosition(_ position: Double) {
        debouncedSaveTask?.cancel()

        debouncedSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PerformanceDefaults.playbackSaveDebounceNanoseconds)
                guard !Task.isCancelled else { return }

                guard abs(position - lastSavedPosition) > 1.0 else { return }

                assertModelContextConfigured()
                book.lastPlaybackPosition = position
                try modelContext?.save()
                lastSavedPosition = position
            } catch is CancellationError {
                // Expected when debounced save is superseded
            } catch {
                AppLogger.playback.error("Failed to save playback position: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func forceSavePlaybackPosition(_ position: Double, errorMessage: String) {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil

        assertModelContextConfigured()
        book.lastPlaybackPosition = position
        do {
            try modelContext?.save()
            lastSavedPosition = position
            clearPositionBackup()
        } catch {
            // Backup to UserDefaults as fallback before showing error
            backupPositionToUserDefaults(position)
            presentPlaybackSaveError(errorMessage)
        }
    }

    private func presentPlaybackSaveError(_ message: String) {
        playbackSaveErrorMessage = message
        withAnimation(.easeOut(duration: AnimationDefaults.shortDuration)) {
            showPlaybackSaveError = true
        }
        playbackSaveErrorTask?.cancel()
        playbackSaveErrorTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: AnimationDefaults.errorToastNanoseconds)
            } catch {
                return
            }
            withAnimation(.easeIn(duration: AnimationDefaults.shortDuration)) {
                showPlaybackSaveError = false
            }
        }
    }

    // MARK: - Chapter Boundary Handling

    private func handleChapterBoundaryIfNeeded(currentTime: Double, isUserDragging: Bool) {
        guard isCurrentBookLoaded() else {
            clearChapterPlaybackSession()
            return
        }
        guard audioPlayer.isPlaying else { return }
        guard !isUserDragging else { return }
        guard var session = chapterPlaybackSession else { return }

        if let lockUntil = chapterTransitionLockUntil {
            if lockUntil > Date() {
                return
            }
            chapterTransitionLockUntil = nil
        }

        guard session.boundaries.indices.contains(session.currentIndex) else {
            clearChapterPlaybackSession()
            return
        }

        let tolerance = PlaybackDefaults.timeObserverInterval * 0.5
        let maxExpectedOvershoot = PlaybackDefaults.timeObserverInterval + 0.25
        let currentBoundary = session.boundaries[session.currentIndex]

        if currentTime < currentBoundary.startTime - tolerance {
            clearChapterPlaybackSession()
            return
        }

        if currentTime > currentBoundary.endTime + maxExpectedOvershoot {
            clearChapterPlaybackSession()
            return
        }

        guard currentTime >= currentBoundary.endTime - tolerance else { return }

        if playbackSettings.autoPlayNextChapter {
            let nextIndex = session.currentIndex + 1
            guard session.boundaries.indices.contains(nextIndex) else {
                clearChapterPlaybackSession()
                return
            }
            let nextBoundary = session.boundaries[nextIndex]
            session.currentIndex = nextIndex
            chapterPlaybackSession = session
            chapterTransitionLockUntil = Date().addingTimeInterval(PlaybackDefaults.timeObserverInterval + 0.25)
            audioPlayer.seek(to: nextBoundary.startTime)
            audioPlayer.updateNowPlayingTitle("\(book.title) - \(nextBoundary.title)")
            AccessibilityNotifications.announce("Now playing chapter \(nextBoundary.title)")
            persistPlaybackPosition(nextBoundary.startTime, errorMessage: "Couldn't save playback position.")
            return
        }

        audioPlayer.seek(to: currentBoundary.endTime)
        audioPlayer.pause()
        persistPlaybackPosition(currentBoundary.endTime, errorMessage: "Couldn't save playback position.")
        clearChapterPlaybackSession()
    }

    // MARK: - Chapter Metadata Helpers

    private var sortedChapters: [Chapter] {
        cachedSortedChapters
    }

    private func updateSortedChapters() {
        cachedSortedChapters = book.chapters.sorted { $0.startTime < $1.startTime }
    }

    private func binarySearchChapter(at time: Double) -> Chapter? {
        guard !sortedChapters.isEmpty else { return nil }

        var low = 0
        var high = sortedChapters.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let chapter = sortedChapters[mid]

            if time < chapter.startTime {
                high = mid - 1
            } else if time >= chapter.endTime {
                low = mid + 1
            } else {
                return chapter
            }
        }

        // Return last chapter if time is beyond end
        if let lastChapter = sortedChapters.last, time >= lastChapter.startTime {
            return lastChapter
        }

        return nil
    }
    
    // MARK: - Periodic Save Timer
    
    private func startPeriodicSaveTimer() {
        periodicSaveTimer?.invalidate()
        periodicSaveTimer = Timer.scheduledTimer(
            withTimeInterval: PerformanceDefaults.periodicPlaybackSaveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isCurrentBookLoaded() else { return }
                // Only save if position has changed significantly
                let currentTime = audioPlayer.currentTime
                guard abs(currentTime - lastSavedPosition) > 1.0 else { return }
                
                // Force save without error UI (silent save for periodic)
                assertModelContextConfigured()
                book.lastPlaybackPosition = currentTime
                do {
                    try modelContext?.save()
                    lastSavedPosition = currentTime
                    // Clear backup after successful save
                    clearPositionBackup()
                } catch {
                    AppLogger.playback.error("Failed to save periodic playback position: \(error.localizedDescription, privacy: .private)")
                    // Backup to UserDefaults as fallback
                    backupPositionToUserDefaults(currentTime)
                }
            }
        }
    }
    
    // MARK: - UserDefaults Backup for Local Books

    private func assertModelContextConfigured() {
        if modelContext == nil {
            assertionFailure("PlayerViewModel: modelContext is nil — configure(modelContext:) must be called before any save operation")
            AppLogger.playback.error("PlayerViewModel: modelContext is nil — playback position will not be persisted")
        }
    }

    private var positionBackupKey: String {
        "localBookPosition_\(book.id.uuidString)"
    }
    
    private func backupPositionToUserDefaults(_ position: Double) {
        let backup: [String: Any] = [
            "currentTime": position,
            "timestamp": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(backup, forKey: positionBackupKey)
        AppLogger.playback.debug("Backed up playback position to UserDefaults: \(position)s")
    }
    
    private func clearPositionBackup() {
        UserDefaults.standard.removeObject(forKey: positionBackupKey)
    }
    
    private func restorePositionFromUserDefaults() -> Double? {
        guard let dict = UserDefaults.standard.dictionary(forKey: positionBackupKey),
              let position = dict["currentTime"] as? Double,
              let backupTimestamp = dict["timestamp"] as? Double else { return nil }
        if let lastPlayed = book.lastPlayedDate,
           lastPlayed.timeIntervalSince1970 > backupTimestamp {
            clearPositionBackup()
            return nil
        }
        return position
    }
}
