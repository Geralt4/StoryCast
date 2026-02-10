import SwiftUI

struct BulkDeleteFoldersConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: LayoutDefaults.contentPadding) {
                Image(systemName: "trash")
                    .font(.system(size: LayoutDefaults.largeIconSize))
                    .foregroundColor(.red)

                Text("Delete \(count) Folder\(count == 1 ? "" : "s")?")
                    .font(.headline)

                Text("This will permanently remove the selected folders and move their books to Unfiled.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: LayoutDefaults.contentPadding) {
                    Button(action: {
                        onCancel()
                        dismiss()
                    }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        HapticManager.impact(.heavy)
                        HapticManager.notification(.warning)
                        onConfirm()
                        dismiss()
                    }) {
                        Text("Delete")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.top, LayoutDefaults.buttonRowSpacing)
            }
            .padding()
            .navigationTitle("Confirm Delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(LayoutDefaults.confirmationSheetHeight)])
    }
}
