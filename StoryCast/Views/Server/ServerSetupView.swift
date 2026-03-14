import SwiftUI
import SwiftData
import os

/// Screen for adding or editing an Audiobookshelf server connection.
struct ServerSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing server to edit it; nil to create a new one.
    var existingServer: ABSServer? = nil

    // MARK: - Form State

    @State private var serverName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    // MARK: - Connection State

    @State private var connectionState: ConnectionState = .idle
    @State private var errorMessage: String?

    enum ConnectionState {
        case idle, checking, success, failure
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverInfoSection
                credentialsSection
                connectionStatusSection
            }
            .navigationTitle(existingServer == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task { await connectAndSave() }
                    }
                    .disabled(!canConnect)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { prefillIfEditing() }
            .interactiveDismissDisabled(connectionState == .checking)
        }
    }

    // MARK: - Sections

    private var serverInfoSection: some View {
        Section {
            TextField("Server Name", text: $serverName)
                .autocorrectionDisabled()
                .accessibilityLabel("Server name")

            TextField("Server URL", text: $serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Server URL")
                .accessibilityHint("Example: https://abs.home.local:13378")
        } header: {
            Text("Server")
        } footer: {
            Text("Enter the full URL including port if needed, e.g. https://abs.home.local:13378")
                .font(.caption)
        }
    }

    private var credentialsSection: some View {
        Section("Credentials") {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .accessibilityLabel("Username")

            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityLabel("Password")
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        if connectionState != .idle {
            Section {
                HStack(spacing: LayoutDefaults.mediumSpacing) {
                    switch connectionState {
                    case .checking:
                        ProgressView()
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected successfully")
                            .foregroundStyle(.green)
                    case .failure:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage ?? "Connection failed")
                            .foregroundStyle(.red)
                    case .idle:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        connectionState != .checking
    }

    private func prefillIfEditing() {
        guard let server = existingServer else { return }
        serverName = server.name
        serverURL = server.url
        username = server.username
    }

    private func connectAndSave() async {
        let trimmedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        connectionState = .checking
        errorMessage = nil

        do {
            let normalizedURL = try AudiobookshelfURLValidator.normalizedBaseURLString(from: serverURL)

            // 1. Verify server is reachable and initialised.
            try await AudiobookshelfAPI.shared.checkServerStatus(baseURL: normalizedURL)

            // 2. Log in and get the token.
            let loginResponse = try await AudiobookshelfAPI.shared.login(
                baseURL: normalizedURL,
                username: trimmedUser,
                password: password
            )

            // 3. Store token in Keychain.
            do {
                try await AudiobookshelfAuth.shared.saveToken(loginResponse.user.token, for: normalizedURL)
            } catch {
                AppLogger.network.error("Failed to save token to Keychain: \(error.localizedDescription, privacy: .private)")
                // Continue anyway - the login succeeded, just can't persist the token
            }

            // 4. Persist the server in SwiftData.
            if let existing = existingServer {
                // If URL changed, delete the old token from Keychain
                if existing.normalizedURL != normalizedURL {
                    do {
                        try await AudiobookshelfAuth.shared.deleteToken(for: existing.normalizedURL)
                    } catch {
                        AppLogger.network.error("Failed to delete old token from Keychain: \(error.localizedDescription, privacy: .private)")
                    }
                }
                existing.name = trimmedName.isEmpty ? trimmedUser : trimmedName
                existing.updateURL(normalizedURL)
                existing.username = trimmedUser
                existing.userId = loginResponse.user.id
                existing.defaultLibraryId = loginResponse.userDefaultLibraryId
                existing.serverVersion = loginResponse.serverSettings?.version
                existing.isActive = true
            } else {
                let server = ABSServer(
                    name: trimmedName.isEmpty ? trimmedUser : trimmedName,
                    url: normalizedURL,
                    username: trimmedUser,
                    userId: loginResponse.user.id,
                    defaultLibraryId: loginResponse.userDefaultLibraryId,
                    serverVersion: loginResponse.serverSettings?.version,
                    isActive: true
                )
                modelContext.insert(server)
            }
            try modelContext.save()

            connectionState = .success
            HapticManager.impact(.medium)

            // Brief pause so the user sees the success state, then dismiss.
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()

        } catch let apiError as APIError {
            connectionState = .failure
            errorMessage = apiError.errorDescription
            HapticManager.notification(.error)
        } catch {
            connectionState = .failure
            errorMessage = error.localizedDescription
            HapticManager.notification(.error)
        }
    }
}

#Preview {
    ServerSetupView()
        .modelContainer(for: [ABSServer.self], inMemory: true)
}
