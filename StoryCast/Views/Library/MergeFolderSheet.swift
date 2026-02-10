import SwiftUI

struct MergeFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sourceFolder: Folder
    let folders: [Folder]
    let onSave: (Folder) -> Void
    let onCancel: () -> Void

    @State private var selectedFolder: Folder?

    private var availableFolders: [Folder] {
        folders.filter { $0.id != sourceFolder.id }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(availableFolders) { folder in
                    Button(action: {
                        HapticManager.impact(.light)
                        selectedFolder = folder
                    }) {
                        HStack {
                            Image(systemName: folder.isSystem ? "tray" : "folder")
                                .foregroundColor(folder.isSystem ? .secondary : .blue)
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
            .navigationTitle("Merge Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        if let folder = selectedFolder {
                            HapticManager.impact(.medium)
                            HapticManager.notification(.success)
                            onSave(folder)
                            dismiss()
                        }
                    }
                    .disabled(selectedFolder == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if selectedFolder == nil {
                selectedFolder = availableFolders.first
            }
        }
    }
}
