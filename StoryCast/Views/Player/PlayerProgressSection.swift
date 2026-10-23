import SwiftUI

struct PlayerProgressSection: View {
    @Binding var sliderValue: Double
    @Binding var isUserDraggingSlider: Bool
    let safeDuration: Double
    let currentTime: Double
    /// The chapter being played. Nil shows the whole book.
    let progress: ChapterProgress?
    /// Time left in the whole book, shown under the bar when `progress` is set.
    let bookRemaining: Double
    let chapterTitleForTime: (Double) -> String?
    let onEditingChanged: (Bool) -> Void

    /// Start and length of the span the bar covers: the chapter, or the whole book.
    private var spanStart: Double { progress?.start ?? 0 }
    private var spanDuration: Double { progress?.duration ?? safeDuration }

    /// Slider position within the span. `sliderValue` stays in book time.
    private var spanSliderValue: Binding<Double> {
        Binding(
            get: { min(max(sliderValue - spanStart, 0), spanDuration) },
            set: { sliderValue = spanStart + $0 }
        )
    }

    private var shownTime: Double { isUserDraggingSlider ? sliderValue : currentTime }
    private var elapsed: Double { min(max(shownTime - spanStart, 0), spanDuration) }
    private var remaining: Double { max(0, spanDuration - elapsed) }

    var body: some View {
        VStack(spacing: LayoutDefaults.smallSpacing) {
            ZStack(alignment: .top) {
                if isUserDraggingSlider {
                    VStack(spacing: LayoutDefaults.tinySpacing) {
                        Text(TimeFormatter.playback(elapsed))
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

                Slider(value: spanSliderValue, in: 0...max(spanDuration, MathDefaults.minDurationSafetyValue), onEditingChanged: onEditingChanged)
                    .tint(.accentColor)
                    .disabled(spanDuration <= 0)
                    .accessibilityLabel(progress == nil ? "Playback position" : "Position in chapter")
                    .accessibilityValue("\(TimeFormatter.playback(elapsed)) of \(TimeFormatter.playback(spanDuration))")
                    .accessibilityHint("Adjust playback position")
            }
            .padding(.horizontal, LayoutDefaults.horizontalPadding)

            HStack {
                Text(TimeFormatter.playback(elapsed))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Current time \(TimeFormatter.playback(elapsed))")

                Spacer()

                Text("-\(TimeFormatter.playback(remaining))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Remaining time \(TimeFormatter.playback(remaining))")
            }
            .padding(.horizontal, LayoutDefaults.horizontalPadding)

            if progress != nil {
                Text("Book: -\(TimeFormatter.playback(bookRemaining)) left")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Book remaining \(TimeFormatter.playback(bookRemaining))")
            }
        }
    }
}
