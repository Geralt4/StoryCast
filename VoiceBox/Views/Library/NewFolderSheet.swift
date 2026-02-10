import SwiftUI

struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder Name", text: $folderName)
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        HapticManager.impact(.medium)
                        HapticManager.notification(.success)
                        onSave(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(LayoutDefaults.smallSheetHeight)])
    }
}
