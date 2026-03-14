import SwiftUI
import SwiftData
import os
#if os(iOS)
import UIKit
#endif
import Combine

struct PlayerView: View {
    let book: Book
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @ObservedObject private var sessionManager = PlaybackSessionManager.shared
    
    // UI State
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showChapterList = false
    @State private var sliderValue = 0.0
    @State private var isUserDraggingSlider = false
    @State private var playbackSettings = PlaybackSettings.load()
    @State private var coverArtUIImage: UIImage?
    @State private var coverArtTask: Task<Void, Never>?
    @State private var chapterExtractionTask: Task<Void, Never>?
    @State private var showMissingFileAlert = false
    @State private var showPlaybackSaveError = false
    @State private var playbackSaveErrorMessage = ""
    @State private var playbackSaveErrorTask: Task<Void, Never>?
    @State private var cachedSortedChapters: [Chapter]
    @State private var chapterPlaybackSession: ChapterPlaybackSession?
    @State private var chapterTransitionLockUntil: Date?
    
    // Remote playback state
    @State private var remotePlaybackTask: Task<Void, Never>?
    @State private var showRemoteServerError = false
    @State private var remoteServerErrorMessage = ""
    
    // Performance optimizations
    @State private var debouncedSaveTask: Task<Void, Never>?
    @State private var lastSavedPosition: Double = -1.0

    private struct ChapterBoundary {
        let title: String
        let startTime: Double
        let endTime: Double
    }

    private struct ChapterPlaybackSession {
        var boundaries: [ChapterBoundary]
        var currentIndex: Int
    }

    init(book: Book) {
        self.book = book
        _cachedSortedChapters = State(initialValue: book.chapters.sorted { $0.startTime < $1.startTime })
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

    private var safeDuration: Double {
        guard book.duration.isFinite, book.duration > 0 else {
            return 0
        }
        return book.duration
    }

    private var skipBackwardSeconds: Int {
        Int(playbackSettings.skipBackwardSeconds.rounded())
    }

    private var skipForwardSeconds: Int {
        Int(playbackSettings.skipForwardSeconds.rounded())
    }

    private var skipBackwardSymbol: String {
        skipSymbolName(for: skipBackwardSeconds, baseName: "gobackward")
    }

    private var skipForwardSymbol: String {
        skipSymbolName(for: skipForwardSeconds, baseName: "goforward")
    }

    private func skipSymbolName(for seconds: Int, baseName: String) -> String {
        let supported = PlaybackDefaults.supportedSkipSymbolIntervals
        let nearest = supported.min { abs($0 - seconds) < abs($1 - seconds) } ?? 15
        return "\(baseName).\(nearest)"
    }

    private func syncSliderValue() {
        let duration = (book.duration.isFinite && book.duration > 0) ? book.duration : 0
        let maxValue = max(duration, MathDefaults.minDurationSafetyValue)
        sliderValue = min(max(book.lastPlaybackPosition, 0), maxValue)
    }

    private func refreshPlaybackSettings() {
        playbackSettings = PlaybackSettings.load()
    }

    private func updateLastPlayedDate() {
        book.lastPlayedDate = Date()
        do {
            try modelContext.save()
        } catch {
            presentPlaybackSaveError("Couldn't save recently played date.")
        }
    }

    private var bookAudioURL: URL {
        if book.isRemote {
            // If downloaded, play from local cache
            if book.isDownloaded, let cachePath = book.localCachePath {
                return StorageManager.shared.remoteAudioCacheURL(for: cachePath)
            }
            // Otherwise, will stream via session (placeholder URL)
            return URL(string: "about:blank")!
        }
        return StorageManager.shared.storyCastLibraryURL.appendingPathComponent(book.localFileName)
    }

    private var usesRemoteStreaming: Bool {
        book.isRemote && !book.isDownloaded
    }

    private func isCurrentBookLoaded(expectedURL: URL? = nil) -> Bool {
        if usesRemoteStreaming {
            return sessionManager.isCurrentSession(for: book)
        }

        return audioPlayer.currentURL == (expectedURL ?? bookAudioURL)
    }
    
    /// Fetches the server configuration for a remote book
    private func fetchServer(for serverId: UUID?) -> ABSServer? {
        guard let serverId = serverId else { return nil }
        let descriptor = FetchDescriptor<ABSServer>(
            predicate: #Predicate { $0.id == serverId }
        )
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            AppLogger.network.error("Failed to fetch server for remote playback: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
    
    /// Starts a remote playback session and returns the authenticated stream
    private func startRemotePlaybackSession() async throws -> AuthenticatedStream {
        guard let server = fetchServer(for: book.serverId) else {
            throw APIError.noActiveServer
        }
        return try await sessionManager.startSession(for: book, server: server)
    }

    var body: some View {
        GeometryReader { geometry in
            let artworkSize = max(0, min(geometry.size.width - LayoutDefaults.artworkHorizontalInset, LayoutDefaults.maxArtworkSize))

            VStack(spacing: 0) {

                // MARK: - Main Player Area (centered)
                VStack(spacing: 24) {
                    Spacer()

                    PlayerArtworkSection(
                        artworkSize: artworkSize,
                        coverArt: coverArtUIImage,
                        title: book.title,
                        currentChapterTitle: chapterAt(time: audioPlayer.currentTime)?.title,
                        isSleepTimerActive: sleepTimer.isActive,
                        sleepTimerRemaining: TimeFormatter.compact(sleepTimer.remainingTime),
                        onSleepTimerTap: { showSleepTimer = true }
                    )

                    PlayerProgressSection(
                        sliderValue: $sliderValue,
                        isUserDraggingSlider: $isUserDraggingSlider,
                        safeDuration: safeDuration,
                        currentTime: audioPlayer.currentTime,
                        chapterTitleForTime: { time in
                            chapterAt(time: time)?.title
                        },
                        onEditingChanged: { editing in
                            if editing {
                                HapticManager.selection()
                            }
                            isUserDraggingSlider = editing
                            if !editing {
                                clearChapterPlaybackSession()
                                audioPlayer.seek(to: sliderValue)
                                persistPlaybackPosition(sliderValue, errorMessage: "Couldn't save playback position.", forceImmediate: true)
                            }
                        }
                    )

                    PlayerControlsSection(
                        book: book,
                        skipBackwardSymbol: skipBackwardSymbol,
                        skipForwardSymbol: skipForwardSymbol,
                        skipBackwardSeconds: skipBackwardSeconds,
                        skipForwardSeconds: skipForwardSeconds,
                        isPlaying: audioPlayer.isPlaying,
                        playbackRate: audioPlayer.playbackRate,
                        isSleepTimerActive: sleepTimer.isActive,
                        showSpeedPicker: $showSpeedPicker,
                        showSleepTimer: $showSleepTimer,
                        showChapterList: $showChapterList,
                        onSkipBackward: {
                            HapticManager.impact(.light)
                            clearChapterPlaybackSession()
                            audioPlayer.skipBackward()
                        },
                        onTogglePlayPause: {
                            HapticManager.impact(.medium)
                            audioPlayer.togglePlayPause()
                        },
                        onSkipForward: {
                            HapticManager.impact(.light)
                            clearChapterPlaybackSession()
                            audioPlayer.skipForward()
                        }
                    )

                    Spacer()
                }
                .padding(.top, LayoutDefaults.playerTopPadding)
                .padding(.bottom, LayoutDefaults.largeSpacing)
            }
        }
        .onAppear {
            audioPlayer.playbackDidReachEnd = false
            syncSliderValue()
            refreshPlaybackSettings()
            updateSortedChapters()
            let audioURL = bookAudioURL
            if audioPlayer.isPlaying, isCurrentBookLoaded(expectedURL: audioURL) {
                updateLastPlayedDate()
            }
            if !isCurrentBookLoaded(expectedURL: audioURL) {
                // Cancel sleep timer when switching to a different book
                // The timer is global and would otherwise carry over, firing
                // against the wrong book (especially problematic in end-of-chapter mode).
                if sleepTimer.isActive {
                    sleepTimer.cancel()
                }
                
                // Cancel any previous remote playback task
                remotePlaybackTask?.cancel()
                
                // Handle remote vs local books
                // If remote and downloaded, play from local cache like a local book
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
                    // For local books, check if file exists before loading
                    Task { @MainActor in
                        let fileExists = await Task.detached(priority: .utility) {
                            FileManager.default.fileExists(atPath: audioURL.path)
                        }.value
                        guard audioPlayer.currentURL != audioURL else { return }
                        if fileExists {
                            audioPlayer.loadAudio(url: audioURL, title: book.title, duration: safeDuration, seekTo: book.lastPlaybackPosition)
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
                    let extractor = MetadataChapterExtractor()
                    let detectedChapters = await Task.detached(priority: .utility) {
                        try? await extractor.extractChapters(from: audioURL)
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
                            modelContext.insert(chapter)
                        }
                        do {
                            try modelContext.save()
                        } catch {
                            AppLogger.ui.error("Error saving new chapters: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showPlaybackSaveError {
                Text(playbackSaveErrorMessage)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, LayoutDefaults.mediumSpacing)
                    .padding(.vertical, LayoutDefaults.smallSpacing)
                    .background(Color.red.opacity(ColorDefaults.errorOpacity))
                    .cornerRadius(LayoutDefaults.smallCornerRadius)
                    .padding(.top, LayoutDefaults.mediumSpacing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onDisappear {
            coverArtTask?.cancel()
            chapterExtractionTask?.cancel()
            playbackSaveErrorTask?.cancel()
            remotePlaybackTask?.cancel()
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
        .onReceive(audioPlayer.$currentTime) { newValue in
            if !isUserDraggingSlider {
                sliderValue = min(max(newValue, 0), max(safeDuration, MathDefaults.minDurationSafetyValue))
            }
            handleChapterBoundaryIfNeeded(currentTime: newValue)
            // Debounce save playback position during active playback
            debouncedSavePlaybackPosition(newValue)
        }
        .onReceive(audioPlayer.$playbackDidReachEnd) { didReachEnd in
            guard didReachEnd else { return }
            handlePlaybackEnd()
        }
        .onChange(of: audioPlayer.isPlaying) { _, isPlaying in
            guard isCurrentBookLoaded() else { return }
            if isPlaying {
                updateLastPlayedDate()
                AccessibilityNotifications.announce("Playing \(book.title)")
            } else {
                AccessibilityNotifications.announce("Paused")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .inactive || newPhase == .background else { return }
            guard isCurrentBookLoaded() else { return }
            forceSavePlaybackPosition(audioPlayer.currentTime, errorMessage: "Couldn't save playback position.")
        }
        .onChange(of: book.chapters.count) { _, _ in
            updateSortedChapters()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshPlaybackSettings()
        }
        .alert("Audio file missing", isPresented: $showMissingFileAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The audio file for this book could not be found. Re-import the book to listen.")
        }
        .alert("Playback Error", isPresented: $showRemoteServerError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(remoteServerErrorMessage)
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView(book: book, onChapterSelected: { chapters, selectedIndex in
                startChapterPlaybackSession(from: chapters, selectedIndex: selectedIndex)
            })
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

    private func handlePlaybackEnd() {
        clearChapterPlaybackSession()
        audioPlayer.pause()
        // Mark the book's position at the end so it shows as fully played
        persistPlaybackPosition(book.duration, errorMessage: "Couldn't save completed playback position.", forceImmediate: true)
    }

    private func persistPlaybackPosition(_ position: Double, errorMessage: String, forceImmediate: Bool = false) {
        if forceImmediate {
            forceSavePlaybackPosition(position, errorMessage: errorMessage)
        } else {
            debouncedSavePlaybackPosition(position)
        }
    }

    private func startChapterPlaybackSession(from chapters: [Chapter], selectedIndex: Int) {
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

    private func clearChapterPlaybackSession() {
        chapterPlaybackSession = nil
        chapterTransitionLockUntil = nil
    }

    private func handleChapterBoundaryIfNeeded(currentTime: Double) {
        guard isCurrentBookLoaded() else {
            clearChapterPlaybackSession()
            return
        }
        guard audioPlayer.isPlaying else { return }
        guard !isUserDraggingSlider else { return }
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
                // No next chapter: return to normal full-book playback behavior.
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

    private func chapterAt(time: Double) -> Chapter? {
        return binarySearchChapter(at: time)
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
    
    private func debouncedSavePlaybackPosition(_ position: Double) {
        // Cancel any pending save
        debouncedSaveTask?.cancel()
        
        // Debounce save during active playback
        debouncedSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PerformanceDefaults.playbackSaveDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                
                // Only save if position changed significantly (> 1 second)
                guard abs(position - lastSavedPosition) > 1.0 else { return }
                
                book.lastPlaybackPosition = position
                try modelContext.save()
                lastSavedPosition = position
            } catch is CancellationError {
                // Expected when debounced save is superseded
            } catch {
                AppLogger.playback.error("Failed to save playback position: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    
    private func forceSavePlaybackPosition(_ position: Double, errorMessage: String) {
        // Cancel debounced task to avoid duplicate saves
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        
        book.lastPlaybackPosition = position
        do {
            try modelContext.save()
            lastSavedPosition = position
        } catch {
            presentPlaybackSaveError(errorMessage)
        }
    }


}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    if let container = try? ModelContainer(for: Book.self, Chapter.self, Folder.self, configurations: config) {
        let book = Book(
title: "Sample Book",
            localFileName: "sample.mp3",
            duration: 3600.0
        )
        return PlayerView(book: book)
            .modelContainer(container)
    }
let book = Book(
            title: "Sample Book",
            localFileName: "sample.mp3",
            duration: 3600.0
        )
        return PlayerView(book: book)
}
