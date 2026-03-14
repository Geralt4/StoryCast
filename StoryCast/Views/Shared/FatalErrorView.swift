import SwiftUI
import UIKit
import MessageUI

struct FatalErrorView: View {
    let error: Error?
    let onReset: () -> Void
    
    @State private var showResetConfirmation = false
    @State private var showResetSuccess = false
    @State private var showMailComposer = false
    @State private var errorDetailsExpanded = false
    
    private var supportEmail: String {
        Bundle.main.object(forInfoDictionaryKey: "SupportEmail") as? String ?? AppConstants.supportEmail
    }
    
    private var errorDescription: String {
        guard let error = error else {
            return "Unknown error occurred while accessing your library data."
        }
        return "Error: \(error.localizedDescription)"
    }
    
    private var deviceInfo: String {
        let device = UIDevice.current
        return """
        Device: \(device.name)
        iOS: \(device.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        """
    }
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                
                Text("Data Access Error")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("StoryCast cannot access your library data. This may be due to database corruption or insufficient storage.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .foregroundStyle(.secondary)
                
                if showResetSuccess {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        
                        Text("All data has been reset.")
                            .font(.headline)
                        
                        Text("The app will restart automatically in 10-30 minutes. Please force-close and reopen StoryCast if it doesn't restart.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top)
                } else {
                    VStack(spacing: 12) {
                        Button(action: {
                            showMailComposer = true
                        }) {
                            Text("Contact Support")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!MailComposerView.canSendMail)
                        
                        Button(action: {
                            showResetConfirmation = true
                        }) {
                            Text("Reset All Data")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top)
                }
                
                DisclosureGroup("Error Details", isExpanded: $errorDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(deviceInfo)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 32)
                .padding(.top, showResetSuccess ? 0 : 16)
                
                Spacer()
            }
        }
        .alert("Reset All Data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                onReset()
                showResetSuccess = true
            }
        } message: {
            Text("This will permanently delete all your audiobooks, playback progress, server connections, and settings. This action cannot be undone.")
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposerView(
                to: supportEmail,
                subject: "StoryCast Database Error",
                body: "Hello,\n\nI need help with a database error in StoryCast.\n\n\(errorDescription)\n\n\(deviceInfo)"
            )
        }
    }
}

struct MailComposerView: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([to])
        mail.setSubject(subject)
        mail.setMessageBody(body, isHTML: false)
        return mail
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}

#Preview {
    FatalErrorView(error: nil, onReset: {})
}