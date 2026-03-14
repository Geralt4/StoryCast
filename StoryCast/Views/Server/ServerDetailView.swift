import SwiftUI
import SwiftData

/// Shows details for a single Audiobookshelf server and lets the user
/// browse its libraries and trigger a sync.
struct ServerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var remoteLibrary = RemoteLibraryService.shared

    let server: ABSServer

    @State private var selectedLibraryId: String?
    @State private var showEditServer = false
    @State private var isActivating = false
    @State private var needsLogin = false

    var body: some View {
        List {
            serverInfoSection
            librarySection
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditServer = true
                } label: {
                    Text("Edit")
                }
            }
        }
        .sheet(isPresented: $showEditServer) {
            ServerSetupView(existingServer: server)
        }
        .alert("Login Required", isPresented: $needsLogin) {
            Button("Edit Server") { showEditServer = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your session has expired. Please log in again.")
        }
        .task { await activateAndFetch() }
    }

    // MARK: - Sections

    private var serverInfoSection: some View {
        Section("Server Info") {
            LabeledContent("URL", value: server.url)
            LabeledContent("Username", value: server.username)
            if let version = server.serverVersion {
                LabeledContent("Version", value: "v\(version)")
            }
            if let syncDate = server.lastSyncDate {
                LabeledContent("Last Synced") {
                    Text(syncDate, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        Section("Libraries") {
            if isActivating {
                HStack {
                    ProgressView()
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = remoteLibrary.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if remoteLibrary.libraries.isEmpty {
                Text("No libraries found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remoteLibrary.libraries) { library in
                    NavigationLink(destination: RemoteLibraryView(server: server, library: library)) {
                        HStack {
                            Image(systemName: "books.vertical")
                                .foregroundStyle(Color.accentColor)
                            Text(library.name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private func activateAndFetch() async {
        isActivating = true
        defer { isActivating = false }

        let tokenValid = await remoteLibrary.activateServer(server, container: modelContext.container)
        if !tokenValid {
            needsLogin = true
            return
        }
        await remoteLibrary.fetchLibraries()
    }
}

#Preview {
    NavigationStack {
        ServerDetailView(server: ABSServer(
            name: "Home Server",
            url: "https://abs.home.local",
            username: "admin"
        ))
    }
    .modelContainer(for: [ABSServer.self, Book.self, Folder.self], inMemory: true)
}
