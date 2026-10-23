import SwiftUI
import SwiftData

/// Shows details for a single Audiobookshelf server and lets the user
/// trigger a sync. The server's books live in the main Library, in a folder
/// named after the server, and play in the main player.
struct ServerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var remoteLibrary = RemoteLibraryService.shared

    let server: ABSServer

    init(server: ABSServer) {
        self.server = server
        let serverId = server.id
        _serverBooks = Query(filter: #Predicate<Book> { $0.serverId == serverId })
    }

    @Query private var serverBooks: [Book]
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?
    @State private var showEditServer = false
    @State private var isActivating = false
    @State private var needsLogin = false

    var body: some View {
        List {
            serverInfoSection
            librarySection
            syncSection
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
                    HStack {
                        Image(systemName: "books.vertical")
                            .foregroundStyle(Color.accentColor)
                        Text(library.name)
                        Spacer()
                        if library.mediaType == "book" {
                            Text("\(bookCount(in: library))")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not supported")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    Text("Sync Now")
                    if isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSyncing || isActivating)
            if let syncErrorMessage {
                Label(syncErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } footer: {
            Text("Synced books appear in your Library, in a folder for this server.")
        }
    }

    private func bookCount(in library: ABSLibrary) -> Int {
        serverBooks.filter { $0.remoteLibraryId == library.id }.count
    }

    // MARK: - Logic

    private func activateAndFetch() async {
        isActivating = true
        defer { isActivating = false }

        let tokenValid = await remoteLibrary.activateServer(server, container: modelContext.container)
        if !tokenValid {
            // activateServer also returns false when a newer activation
            // superseded this one. Only prompt for login when this server
            // is still the active target.
            if remoteLibrary.activeServer?.id == server.id || remoteLibrary.activeServer == nil {
                needsLogin = true
            }
            return
        }
        await remoteLibrary.fetchLibraries()
    }

    private func syncNow() async {
        isSyncing = true
        syncErrorMessage = nil
        defer { isSyncing = false }

        let result = await RemoteLibrarySyncEngine.syncServer(for: server.snapshot(), container: modelContext.container)
        switch result.outcome {
        case .synced: break
        case .skippedNoToken: needsLogin = true
        case .skippedNoLibraries: syncErrorMessage = "This server has no book libraries."
        case .failed(let message): syncErrorMessage = message
        }
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
