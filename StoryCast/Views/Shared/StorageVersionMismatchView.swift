import SwiftUI

/// View displayed when a schema version mismatch is detected
struct StorageVersionMismatchView: View {
    let error: StorageVersionError
    let onRecoveryComplete: (StorageBootstrapState) -> Void
    
    @State private var recoveryState: RecoveryState = .idle
    @State private var backupURL: URL?
    
    private enum RecoveryState {
        case idle
        case inProgress
        case success
        case failed(message: String)
    }
    
    private var userMessage: String {
        StorageVersionValidator.userMessage(for: error)
    }
    
    private var technicalDetails: String {
        StorageVersionValidator.technicalDetails(for: error)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                
                switch recoveryState {
                case .idle:
                    idleContent
                case .inProgress:
                    inProgressContent
                case .success:
                    successContent
                case .failed(let message):
                    failedContent(message: message)
                }
                
                Spacer()
            }
            .navigationTitle("StoryCast")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    @ViewBuilder
    private var idleContent: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 60))
            .foregroundStyle(.orange)
        
        Text("Library Update Required")
            .font(.title)
            .fontWeight(.bold)
        
        Text(userMessage)
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .foregroundStyle(.secondary)
        
        VStack(spacing: 12) {
            Button(action: startRecovery) {
                Text("Recover Library")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 32)
        .padding(.top)
        
        DisclosureGroup("Technical Details", isExpanded: .constant(false)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(technicalDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding(.horizontal, 32)
        .padding(.top)
    }
    
    @ViewBuilder
    private var inProgressContent: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .scaleEffect(1.5)
            .padding()
        
        Text("Recovering Library...")
            .font(.title2)
            .fontWeight(.bold)
        
        Text("Please wait while we backup your data and create a new library.")
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .foregroundStyle(.secondary)
    }
    
    @ViewBuilder
    private var successContent: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 60))
            .foregroundStyle(.green)
        
        Text("Recovery Complete")
            .font(.title)
            .fontWeight(.bold)
        
        Text("Your library has been recovered successfully.")
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .foregroundStyle(.secondary)
        
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text("Backup saved")
                    .font(.subheadline)
            }
            
            if let backupURL = backupURL {
                Text(backupURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .padding(.horizontal, 32)
        
        Text("Please close and reopen the app to continue.")
            .font(.headline)
            .foregroundStyle(.orange)
            .padding(.top)
    }
    
    @ViewBuilder
    private func failedContent(message: String) -> some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 60))
            .foregroundStyle(.red)
        
        Text("Recovery Failed")
            .font(.title)
            .fontWeight(.bold)
        
        Text(message)
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .foregroundStyle(.secondary)
        
        VStack(spacing: 12) {
            Button(action: startRecovery) {
                Text("Try Again")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            
            Button(action: {}) {
                Text("Contact Support")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
        .padding(.top)
    }
    
    private func startRecovery() {
        recoveryState = .inProgress
        
        Task {
            let state = await AppBootstrap.startFresh()
            
            // Store backup URL for display
            backupURL = StorageBackupManager.listBackups().first
            
            switch state {
            case .ready:
                recoveryState = .success
            case .unrecoverable(let error):
                recoveryState = .failed(message: error.localizedDescription)
            default:
                recoveryState = .failed(message: "An unexpected error occurred")
            }
            
            onRecoveryComplete(state)
        }
    }
}

#Preview {
    StorageVersionMismatchView(
        error: .versionMismatchDetected(details: "Schema version mismatch"),
        onRecoveryComplete: { _ in }
    )
}
