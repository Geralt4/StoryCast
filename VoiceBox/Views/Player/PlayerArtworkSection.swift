import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PlayerArtworkSection: View {
    let artworkSize: CGFloat
    let coverArt: UIImage?
    let title: String
    let currentChapterTitle: String?
    let isSleepTimerActive: Bool
    let sleepTimerRemaining: String
    let onSleepTimerTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let coverArt {
                    Image(uiImage: coverArt)
                        .resizable()
                        .scaledToFill()
                        .frame(width: artworkSize, height: artworkSize)
                        .clipped()
                        .accessibilityLabel("Album artwork for \(title)")
                } else {
                    RoundedRectangle(cornerRadius: LayoutDefaults.largeCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(ColorDefaults.gradientStartOpacity),
                                    Color.accentColor.opacity(ColorDefaults.gradientEndOpacity)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: LayoutDefaults.bookIconSize))
                            .foregroundColor(.accentColor.opacity(ColorDefaults.iconOpacity))

                        if let currentChapterTitle {
                            Text(currentChapterTitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, LayoutDefaults.contentPadding)
                        }
                    }
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: LayoutDefaults.largeCornerRadius))
            .shadow(color: .black.opacity(ColorDefaults.subtleOpacity), radius: LayoutDefaults.shadowRadius, x: 0, y: LayoutDefaults.shadowYOffset)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutDefaults.horizontalPadding)
                .accessibilityLabel("Title: \(title)")

            if isSleepTimerActive {
                Button(action: onSleepTimerTap) {
                    Label(sleepTimerRemaining, systemImage: "moon.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, LayoutDefaults.mediumSpacing)
                        .padding(.vertical, LayoutDefaults.badgeVerticalPadding)
                        .background(Color.orange.opacity(ColorDefaults.badgeOpacity))
                        .cornerRadius(LayoutDefaults.badgeCornerRadius)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sleep timer active")
                .accessibilityValue(sleepTimerRemaining)
                .accessibilityHint("Tap to adjust timer")
            }
        }
    }
}
