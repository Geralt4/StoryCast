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

    @State private var viewModel: PlayerViewModel
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showChapterList = false
    @State private var sliderValue = 0.0
    @State private var isUserDraggingSlider = false

    init(book: Book) {
        self.book = book
        _viewModel = State(initialValue: PlayerViewModel(book: book))
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
                        coverArt: viewModel.coverArtUIImage,
                        title: book.title,
                        currentChapterTitle: viewModel.chapterAt(time: audioPlayer.currentTime)?.title,
                        isSleepTimerActive: sleepTimer.isActive,
                        sleepTimerRemaining: TimeFormatter.compact(sleepTimer.remainingTime),
                        onSleepTimerTap: { showSleepTimer = true }
                    )

                    PlayerProgressSection(
                        sliderValue: $sliderValue,
                        isUserDraggingSlider: $isUserDraggingSlider,
                        safeDuration: viewModel.safeDuration,
                        currentTime: audioPlayer.currentTime,
                        chapterTitleForTime: { time in
                            viewModel.chapterAt(time: time)?.title
                        },
                        onEditingChanged: { editing in
                            isUserDraggingSlider = editing
                            viewModel.sliderValueForSeek = sliderValue
                            viewModel.handleSliderEditingChanged(editing)
                        }
                    )

                    PlayerControlsSection(
                        book: book,
                        skipBackwardSymbol: viewModel.skipBackwardSymbol,
                        skipForwardSymbol: viewModel.skipForwardSymbol,
                        skipBackwardSeconds: viewModel.skipBackwardSeconds,
                        skipForwardSeconds: viewModel.skipForwardSeconds,
                        isPlaying: audioPlayer.isPlaying,
                        playbackRate: audioPlayer.playbackRate,
                        isSleepTimerActive: sleepTimer.isActive,
                        showSpeedPicker: $showSpeedPicker,
                        showSleepTimer: $showSleepTimer,
                        showChapterList: $showChapterList,
                        onSkipBackward: { viewModel.skipBackward() },
                        onTogglePlayPause: { viewModel.togglePlayPause() },
                        onSkipForward: { viewModel.skipForward() }
                    )

                    Spacer()
                }
                .padding(.top, LayoutDefaults.playerTopPadding)
                .padding(.bottom, LayoutDefaults.largeSpacing)
            }
        }
        .onAppear {
            viewModel.configure(modelContext: modelContext)
            sliderValue = viewModel.syncSliderValue()
            viewModel.onAppear()
        }
        .overlay(alignment: .top) {
            if viewModel.showPlaybackSaveError {
                Text(viewModel.playbackSaveErrorMessage)
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
            viewModel.onDisappear()
        }
        .onReceive(audioPlayer.$currentTime) { newValue in
            if !isUserDraggingSlider {
                sliderValue = min(max(newValue, 0), max(viewModel.safeDuration, MathDefaults.minDurationSafetyValue))
            }
            viewModel.handleCurrentTimeUpdate(newValue, isUserDragging: isUserDraggingSlider)
        }
        .onReceive(audioPlayer.$playbackDidReachEnd) { didReachEnd in
            guard didReachEnd else { return }
            viewModel.handlePlaybackDidReachEnd()
        }
        .onChange(of: audioPlayer.isPlaying) { _, isPlaying in
            viewModel.handlePlaybackStateChange(isPlaying: isPlaying)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
        .onChange(of: book.chapters.count) { _, _ in
            viewModel.handleChaptersCountChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            viewModel.handleUserDefaultsChange()
        }
        .alert("Audio file missing", isPresented: $viewModel.showMissingFileAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The audio file for this book could not be found. Re-import the book to listen.")
        }
        .alert("Playback Error", isPresented: $viewModel.showRemoteServerError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.remoteServerErrorMessage)
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView(book: book, onChapterSelected: { chapters, selectedIndex in
                viewModel.startChapterPlaybackSession(from: chapters, selectedIndex: selectedIndex)
            })
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Book.self, Chapter.self, Folder.self, configurations: config)
    let book = Book(
        title: "Sample Book",
        localFileName: "sample.mp3",
        duration: 3600.0
    )
    return PlayerView(book: book)
        .modelContainer(container)
}
