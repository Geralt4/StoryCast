import SwiftUI

struct StorageRecoveryView: View {
    let failure: StorageInitializationFailure

    @State private var isRecovering = false
    @State private var recoveryComplete = false
    @State private var recoveryError: String?

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Storage Unavailable", systemImage: "externaldrive.badge.xmark")
            } description: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure.message)
                    Text(failure.recoverySuggestion)
                        .foregroundStyle(.secondary)
                    
                    if recoveryComplete {
                        Label("Recovery complete. Please restart the app.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .padding(.top, 8)
                    } else if let error = recoveryError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .padding(.top, 8)
                    }
                    
                    Text("Technical details: \(failure.technicalDetails)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                if recoveryComplete {
                    Text("Recovery Complete")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else if isRecovering {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Recovering...")
                            .font(.headline)
                    }
                } else {
                    Button(action: startRecovery) {
                        Text("Start Fresh")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding(.horizontal, 32)
                }
            }
            .navigationTitle("StoryCast")
        }
    }
    
    private func startRecovery() {
        isRecovering = true
        recoveryError = nil
        
        Task {
            let state = await AppBootstrap.startFresh()
            
            await MainActor.run {
                isRecovering = false
                
                switch state {
                case .ready:
                    recoveryComplete = true
                case .unrecoverable(let error):
                    recoveryError = error.localizedDescription
                default:
                    recoveryError = "An unexpected error occurred"
                }
            }
        }
    }
}
