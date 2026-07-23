import SwiftUI

/// View displayed when a schema version mismatch is detected
struct StorageVersionMismatchView: View {
    let error: StorageVersionError
    
    @State private var recoveryState: RecoveryState = .idle
    @State private var backupURL: URL?
    @State private var showTechnicalDetails = false
    
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
                Text("Create New Library")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 32)
        .padding(.top)
        
        DisclosureGroup("Technical Details", isExpanded: $showTechnicalDetails) {
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
        
        Text("Creating New Library...")
            .font(.title2)
            .fontWeight(.bold)
        
        Text("Please wait while we preserve a backup and create a new empty library.")
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
        
        Text("New Library Created")
            .font(.title)
            .fontWeight(.bold)
        
        Text("A new empty library is ready. Your previous database backup is preserved below.")
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
            let outcome = await AppBootstrap.startFresh()

            switch outcome {
            case .restartRequired(let createdBackupURL):
                backupURL = createdBackupURL
                recoveryState = .success
            case .failed(let error):
                recoveryState = .failed(message: error.localizedDescription)
            }
        }
    }
}

#Preview {
    StorageVersionMismatchView(
        error: .versionMismatchDetected(details: "Schema version mismatch")
    )
}
