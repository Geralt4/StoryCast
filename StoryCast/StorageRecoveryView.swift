import SwiftUI

struct StorageRecoveryView: View {
    let failure: StorageInitializationFailure

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Storage Unavailable", systemImage: "externaldrive.badge.xmark")
            } description: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure.message)
                    Text(failure.recoverySuggestion)
                        .foregroundStyle(.secondary)
                    Text("Technical details: \(failure.technicalDetails)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                Text("Recovery Mode")
                    .font(.headline)
            }
            .navigationTitle("StoryCast")
        }
    }
}
