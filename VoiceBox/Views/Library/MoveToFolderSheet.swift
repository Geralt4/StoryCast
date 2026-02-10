import SwiftUI

struct MoveToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let book: Book
    let folders: [Folder]
    let onSave: (Folder) -> Void
    let onCancel: () -> Void

    @State private var selectedFolder: Folder?

    private var currentFolder: Folder? {
        book.folder
    }

    private var unfiledFolder: Folder? {
        folders.first { $0.isSystem }
    }

    private var userFolders: [Folder] {
        folders.filter { !$0.isSystem }
    }

    var body: some View {
        NavigationStack {
            List {
                if let unfiled = unfiledFolder {
                    Button(action: {
                        HapticManager.impact(.light)
                        selectedFolder = unfiled
                    }) {
                        HStack {
                            Image(systemName: "tray")
                                .foregroundColor(.secondary)
                            Text("Unfiled")
                            Spacer()
                            if currentFolder?.id == unfiled.id {
                                Text("Current")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if selectedFolder?.id == unfiled.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                    .disabled(currentFolder?.id == unfiled.id)
                }

                ForEach(userFolders) { folder in
                    Button(action: {
                        HapticManager.impact(.light)
                        selectedFolder = folder
                    }) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                            Text(folder.name)
                            Spacer()
                            if currentFolder?.id == folder.id {
                                Text("Current")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if selectedFolder?.id == folder.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                    .disabled(currentFolder?.id == folder.id)
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        if let folder = selectedFolder {
                            HapticManager.impact(.medium)
                            HapticManager.notification(.success)
                            onSave(folder)
                            dismiss()
                        }
                    }
                    .disabled(selectedFolder == nil || selectedFolder?.id == currentFolder?.id)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
