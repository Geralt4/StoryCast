import SwiftUI

/// A small cloud badge shown on remote (Audiobookshelf) books.
struct BookSourceBadge: View {
    var isDownloaded: Bool = false

    var body: some View {
        Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "cloud.fill")
            .font(.caption2)
            .foregroundStyle(isDownloaded ? Color.green : Color.accentColor)
            .accessibilityLabel(isDownloaded ? "Downloaded" : "Streaming from server")
    }
}

/// Sync status indicator shown during/after a progress sync.
struct SyncStatusIndicator: View {
    enum Status {
        case idle, syncing, synced, error
    }

    let status: Status

    var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .syncing:
                ProgressView()
                    .scaleEffect(0.7)
                    .accessibilityLabel("Syncing progress")
            case .synced:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .accessibilityLabel("Progress synced")
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .accessibilityLabel("Sync error")
            }
        }
    }
}

/// Overlay shown while a remote stream is buffering.
struct BufferingIndicator: View {
    var body: some View {
        ZStack {
            Color.black.opacity(ColorDefaults.overlayOpacity)
                .ignoresSafeArea()
            VStack(spacing: LayoutDefaults.mediumSpacing) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
                Text("Buffering…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(LayoutDefaults.contentPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LayoutDefaults.overlayCornerRadius))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Buffering audio")
    }
}

#Preview {
    VStack(spacing: 20) {
        BookSourceBadge()
        BookSourceBadge(isDownloaded: true)
        SyncStatusIndicator(status: .syncing)
        SyncStatusIndicator(status: .synced)
        SyncStatusIndicator(status: .error)
        BufferingIndicator()
    }
    .padding()
}
