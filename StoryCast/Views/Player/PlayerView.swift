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

        let coverArtURL = StorageManager.shared.coverArtURL(for: fileName)
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
        StorageManager.shared.storyCastLibraryURL.appendingPathComponent(book.localFileName)
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
                                book.lastPlaybackPosition = sliderValue
                                do {
                                    try modelContext.save()
                                } catch {
                                    presentPlaybackSaveError("Couldn't save playback position.")
                                }
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
            if audioPlayer.isPlaying, audioPlayer.currentURL == audioURL {
                updateLastPlayedDate()
            }
            if audioPlayer.currentURL != bookAudioURL {
                // Cancel sleep timer when switching to a different book
                // The timer is global and would otherwise carry over, firing
                // against the wrong book (especially problematic in end-of-chapter mode).
                if sleepTimer.isActive {
                    sleepTimer.cancel()
                }
                // Check if file exists before loading
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

            // Load cover art asynchronously
            coverArtTask?.cancel()
            coverArtTask = Task { @MainActor in
                await loadCoverArt()
                guard !Task.isCancelled else { return }
                guard audioPlayer.currentURL == audioURL else { return }
                audioPlayer.updateNowPlayingInfo(title: book.title, duration: safeDuration, currentTime: audioPlayer.currentTime, artwork: coverArtUIImage)
            }

            // Lazy extract embedded chapters if none exist
            if book.chapters.isEmpty {
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
            clearChapterPlaybackSession()
            // Save playback position only if this book is still loaded
            guard audioPlayer.currentURL == bookAudioURL else { return }
            book.lastPlaybackPosition = audioPlayer.currentTime
            do {
                try modelContext.save()
            } catch {
                presentPlaybackSaveError("Couldn't save playback position.")
            }
        }
        .onReceive(audioPlayer.$currentTime) { newValue in
            if !isUserDraggingSlider {
                sliderValue = min(max(newValue, 0), max(safeDuration, MathDefaults.minDurationSafetyValue))
            }
            handleChapterBoundaryIfNeeded(currentTime: newValue)
        }
        .onReceive(audioPlayer.$playbackDidReachEnd) { didReachEnd in
            guard didReachEnd else { return }
            handlePlaybackEnd()
        }
        .onChange(of: audioPlayer.isPlaying) { _, isPlaying in
            guard audioPlayer.currentURL == bookAudioURL else { return }
            if isPlaying {
                updateLastPlayedDate()
                AccessibilityNotifications.announce("Playing \(book.title)")
            } else {
                AccessibilityNotifications.announce("Paused")
            }
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
        persistPlaybackPosition(book.duration, errorMessage: "Couldn't save completed playback position.")
    }

    private func persistPlaybackPosition(_ position: Double, errorMessage: String) {
        book.lastPlaybackPosition = position
        do {
            try modelContext.save()
        } catch {
            presentPlaybackSaveError(errorMessage)
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
        guard audioPlayer.currentURL == bookAudioURL else {
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
        sortedChapters.first { time >= $0.startTime && time < $0.endTime }
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
