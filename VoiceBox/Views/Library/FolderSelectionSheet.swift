import SwiftUI

struct FolderSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [Folder]
    @Binding var selectedFolder: Folder?
    let onSave: () -> Void

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
                            if selectedFolder?.id == unfiled.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)
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
                            if selectedFolder?.id == folder.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Select Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        HapticManager.impact(.medium)
                        HapticManager.notification(.success)
                        onSave()
                        dismiss()
                    }
                    .disabled(selectedFolder == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if selectedFolder == nil {
                selectedFolder = unfiledFolder
            }
        }
    }
}
