import SwiftUI

struct PlayerControlsSection: View {
    let book: Book
    let skipBackwardSymbol: String
    let skipForwardSymbol: String
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let isPlaying: Bool
    let playbackRate: Float
    let isSleepTimerActive: Bool
    @Binding var showSpeedPicker: Bool
    @Binding var showSleepTimer: Bool
    @Binding var showChapterList: Bool
    let onSkipBackward: () -> Void
    let onTogglePlayPause: () -> Void
    let onSkipForward: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LayoutDefaults.largeSpacing) {
                Button(action: onSkipBackward) {
                    Image(systemName: skipBackwardSymbol)
                        .font(.title)
                }
                .accessibilityLabel("Skip backward \(skipBackwardSeconds) seconds")

                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .frame(width: LayoutDefaults.playButtonSize, height: LayoutDefaults.playButtonSize)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button(action: onSkipForward) {
                    Image(systemName: skipForwardSymbol)
                        .font(.title)
                }
                .accessibilityLabel("Skip forward \(skipForwardSeconds) seconds")
            }
            .padding(.vertical, LayoutDefaults.smallSpacing)

            HStack(spacing: LayoutDefaults.largeSpacing) {
                Button(action: { showSpeedPicker = true }) {
                    VStack(spacing: LayoutDefaults.controlLabelSpacing) {
                        Text(String(format: "%.1fx", playbackRate))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Speed")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: LayoutDefaults.secondaryControlWidth)
                }
                .accessibilityLabel("Playback speed")
                .accessibilityValue(String(format: "%.1f times", playbackRate))
                .accessibilityHint("Adjusts playback speed")
                .sheet(isPresented: $showSpeedPicker) {
                    SpeedPickerView()
                }

                Button(action: { showChapterList = true }) {
                    VStack(spacing: LayoutDefaults.controlLabelSpacing) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.title3)
                        Text("Chapters")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: LayoutDefaults.secondaryControlWidth)
                }
                .accessibilityLabel("Chapters")
                .accessibilityHint("View and select chapters")

                AirPlayRoutePickerView()

                Button(action: { showSleepTimer = true }) {
                    VStack(spacing: LayoutDefaults.controlLabelSpacing) {
                        Image(systemName: isSleepTimerActive ? "moon.fill" : "moon")
                            .font(.title3)
                        Text("Sleep")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: LayoutDefaults.secondaryControlWidth)
                }
                .accessibilityLabel("Sleep timer")
                .accessibilityValue(isSleepTimerActive ? "Active" : "Inactive")
                .accessibilityHint("Set sleep timer")
                .sheet(isPresented: $showSleepTimer) {
                    SleepTimerView(book: book)
                }
            }

            Spacer().frame(height: LayoutDefaults.mediumSpacing)
        }
    }
}
