import SwiftUI

struct FolderRowView: View {
    let folder: Folder
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: () -> Void

    private var folderAccessibilityValue: String {
        let countLabel = folder.bookCount == 1 ? "1 book" : "\(folder.bookCount) books"
        let typeLabel = folder.isSystem ? ", system folder" : ""
        let selectionLabel = isEditing ? (isSelected ? ", selected" : ", not selected") : ""
        return "\(countLabel)\(typeLabel)\(selectionLabel)"
    }

    private var folderAccessibilityHint: String {
        if folder.isSystem {
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
                .disabled(folder.isSystem)
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
            guard !folder.isSystem else { return }
            HapticManager.impact(.light)
            onSelect()
        }
        .contextMenu(folder.isSystem ? nil : ContextMenu {
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
            Button(action: {
                HapticManager.impact(.light)
                onRename()
            }) {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive, action: {
                HapticManager.impact(.heavy)
                HapticManager.notification(.error)
                onDelete()
            }) {
                Label("Delete", systemImage: "trash")
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
            if !isEditing && !folder.isSystem {
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
