import SwiftUI

struct BulkMoveFoldersSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folderIds: Set<UUID>
    let folders: [Folder]
    let onSave: (Folder) -> Void
    let onCancel: () -> Void

    @State private var selectedFolder: Folder?

    private var userFolders: [Folder] {
        folders.filter { !$0.isSystem && !folderIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if userFolders.isEmpty {
                    ContentUnavailableView {
                        Label("No Folders Available", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("There are no other folders to merge into. Create a new folder first.")
                    }
                } else {
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
            }
            .navigationTitle("Merge \(folderIds.count) Folder\(folderIds.count == 1 ? "" : "s")")
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
                selectedFolder = userFolders.first
            }
        }
    }
}
