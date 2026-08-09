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

#Preview {
    VStack(spacing: 20) {
        BookSourceBadge()
        BookSourceBadge(isDownloaded: true)
        SyncStatusIndicator(status: .syncing)
        SyncStatusIndicator(status: .synced)
        SyncStatusIndicator(status: .error)
    }
    .padding()
}
