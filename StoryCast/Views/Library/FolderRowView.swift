import SwiftUI

struct FolderRowView: View {
    let folder: Folder
    /// Folder filled by an Audiobookshelf server: it can be renamed but not selected, merged or deleted.
    let isServerManaged: Bool
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: () -> Void

    private var isLocked: Bool { folder.isSystem || isServerManaged }

    private var folderAccessibilityValue: String {
        let countLabel = folder.bookCount == 1 ? "1 book" : "\(folder.bookCount) books"
        let typeLabel = folder.isSystem ? ", system folder" : ""
        let selectionLabel = isEditing ? (isSelected ? ", selected" : ", not selected") : ""
        return "\(countLabel)\(typeLabel)\(selectionLabel)"
    }

    private var folderAccessibilityHint: String {
        if isLocked {
            return "Double tap to open folder"
        }
        if isEditing {
            return isSelected ? "Double tap to deselect this folder" : "Double tap to select this folder"
        }
        return "Double tap to open folder"
    }

    private var folderSelectionActionName: String {
        isSelected ? "Deselect folder" : "Select folder"
    }

    var body: some View {
        Group {
            if isEditing {
                Button(action: {
                    HapticManager.impact(.light)
                    onSelect()
                }) {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                        Image(systemName: folder.isSystem ? "tray" : "folder")
                            .foregroundColor(folder.isSystem ? .secondary : .blue)
                        Text(folder.name)
                        Spacer()
                        Text("\(folder.bookCount)")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
            } else {
                NavigationLink(value: folder) {
                    HStack {
                        Image(systemName: folder.isSystem ? "tray" : "folder")
                            .foregroundColor(folder.isSystem ? .secondary : .blue)
                        Text(folder.name)
                        Spacer()
                        Text("\(folder.bookCount)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue(folderAccessibilityValue)
        .accessibilityHint(folderAccessibilityHint)
        .accessibilityAction(named: Text(folderSelectionActionName)) {
            guard !isLocked else { return }
            HapticManager.impact(.light)
            onSelect()
        }
        .contextMenu(folder.isSystem ? nil : ContextMenu {
            if !isServerManaged {
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
                    Label("Merge", systemImage: "folder")
                }
            }
            Button(action: {
                HapticManager.impact(.light)
                onRename()
            }) {
                Label("Rename", systemImage: "pencil")
            }
            if !isServerManaged {
                Button(role: .destructive, action: {
                    HapticManager.impact(.heavy)
                    HapticManager.notification(.error)
                    onDelete()
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        })
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isEditing && !folder.isSystem {
                Button(action: {
                    HapticManager.impact(.light)
                    onRename()
                }) {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isEditing && !isLocked {
                Button(role: .destructive, action: {
                    HapticManager.impact(.heavy)
                    HapticManager.notification(.error)
                    onDelete()
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
