import SwiftUI

struct PlayerProgressSection: View {
    @Binding var sliderValue: Double
    @Binding var isUserDraggingSlider: Bool
    let safeDuration: Double
    let currentTime: Double
    let chapterTitleForTime: (Double) -> String?
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: LayoutDefaults.smallSpacing) {
            ZStack(alignment: .top) {
                if isUserDraggingSlider {
                    VStack(spacing: LayoutDefaults.tinySpacing) {
                        Text(TimeFormatter.playback(sliderValue))
                            .font(.caption)
                            .fontWeight(.semibold)

                        if let chapterTitle = chapterTitleForTime(sliderValue) {
                            Text(chapterTitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, LayoutDefaults.mediumSpacing)
                    .padding(.vertical, LayoutDefaults.smallSpacing)
                    .background(.ultraThinMaterial)
                    .cornerRadius(LayoutDefaults.smallCornerRadius)
                    .offset(y: -LayoutDefaults.tooltipOffset)
                }

                Slider(value: $sliderValue, in: 0...max(safeDuration, MathDefaults.minDurationSafetyValue), onEditingChanged: onEditingChanged)
                    .tint(.accentColor)
                    .disabled(safeDuration <= 0)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(TimeFormatter.playback(sliderValue))")
                    .accessibilityHint("Adjust playback position")
            }
            .padding(.horizontal, LayoutDefaults.horizontalPadding)

            HStack {
                Text(TimeFormatter.playback(currentTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Current time \(TimeFormatter.playback(currentTime))")

                Spacer()

                Text("-\(TimeFormatter.playback(max(0, safeDuration - (isUserDraggingSlider ? sliderValue : currentTime))))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Remaining time \(TimeFormatter.playback(max(0, safeDuration - (isUserDraggingSlider ? sliderValue : currentTime))))")
            }
            .padding(.horizontal, LayoutDefaults.horizontalPadding)
        }
    }
}
