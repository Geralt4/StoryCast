import SwiftUI
import SwiftData

struct BookRowView: View, Equatable {
    let book: Book
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    var onDownload: () -> Void = {}
    var onRemoveDownload: () -> Void = {}

    init(
        book: Book,
        isEditing: Bool = false,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {},
        onMove: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onDownload: @escaping () -> Void = {},
        onRemoveDownload: @escaping () -> Void = {}
    ) {
        self.book = book
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onMove = onMove
        self.onDelete = onDelete
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
    }
    
    static func == (lhs: BookRowView, rhs: BookRowView) -> Bool {
        // Compare by book ID and selection state - closures are not compared
        let sameBook = lhs.book.id == rhs.book.id
        let sameEditing = lhs.isEditing == rhs.isEditing
        let sameSelected = lhs.isSelected == rhs.isSelected
        return sameBook && sameEditing && sameSelected
    }

    var body: some View {
        rowContent
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(book.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAction(named: Text(isEditing ? (isSelected ? "Deselect" : "Select") : "Select")) {
                onSelect()
            }
            .accessibilityAction(named: Text("Move to folder")) {
                onMove()
            }
            .accessibilityAction(named: Text("Delete book")) {
                onDelete()
            }
            .contextMenu {
                Button(action: {
                    HapticManager.impact(.light)
                    onSelect()
                }) {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Button(action: {
                    HapticManager.impact(.light)
                    onMove()
                }) {
                    Label("Move", systemImage: "folder")
                }
                
                // Remote book actions
                if book.isRemote {
                    if book.isDownloaded {
                        Button(action: {
                            HapticManager.impact(.light)
                            onRemoveDownload()
                        }) {
                            Label("Remove Download", systemImage: "icloud.and.arrow.down")
                        }
                    } else {
                        Button(action: {
                            HapticManager.impact(.light)
                            onDownload()
                        }) {
                            Label("Download for Offline", systemImage: "icloud.and.arrow.down")
                        }
                    }
                }
                
                Button(role: .destructive, action: {
                    HapticManager.impact(.heavy)
                    HapticManager.notification(.error)
                    onDelete()
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private var rowContent: some View {
        Group {
            if isEditing {
                Button(action: onSelect) {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                        bookInfoView
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: book) {
                    bookInfoView
                }
            }
        }
    }

    private var bookInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(book.title)
                    .font(.headline)
                if book.isRemote {
                    Spacer()
                    Image(systemName: book.isDownloaded ? "icloud.and.arrow.down.fill" : "icloud")
                        .foregroundColor(book.isDownloaded ? .green : .secondary)
                        .font(.caption)
                        .accessibilityLabel(book.isDownloaded ? "Downloaded for offline" : "Remote book")
                }
            }
            Text(formatDuration(book.duration))
                .font(.caption)
                .foregroundColor(.secondary)
            if let fraction = progressFraction {
                HStack(spacing: 6) {
                    ProgressView(value: fraction, total: 1.0)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Progress")
                        .accessibilityValue(progressPercentageText(for: fraction))
                    Text(progressPercentageText(for: fraction))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var progressFraction: Double? {
        guard book.duration.isFinite, book.duration > 0 else { return nil }
        guard book.lastPlaybackPosition > 0 else { return nil }
        let ratio = book.lastPlaybackPosition / book.duration
        return min(max(ratio, 0), 1)
    }

    private func progressPercentageText(for progress: Double) -> String {
        let percentage = Int(round(progress * 100))
        return "\(percentage)%"
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0 else { return "--:--" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private var progressAccessibilityValue: String {
        guard let fraction = progressFraction else { return "" }
        return ", \(progressPercentageText(for: fraction)) complete"
    }

    private var accessibilityValue: String {
        let selectionValue: String
        if isEditing {
            selectionValue = isSelected ? ", selected" : ", not selected"
        } else {
            selectionValue = ""
        }

        return "Duration \(formatDuration(book.duration))\(progressAccessibilityValue)\(selectionValue)"
    }

    private var accessibilityHint: String {
        if isEditing {
            return isSelected ? "Double tap to deselect this book" : "Double tap to select this book"
        }
        return "Double tap to play book"
    }
}
