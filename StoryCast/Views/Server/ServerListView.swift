import SwiftUI
import SwiftData
import os

/// Lists all configured Audiobookshelf servers and lets the user add/remove them.
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ABSServer.createdAt) private var servers: [ABSServer]

    @State private var showAddServer = false
    @State private var serverToEdit: ABSServer?
    @State private var serverToDelete: ABSServer?
    @State private var showDeleteConfirmation = false
    @State private var deletionErrorMessage = ""
    @State private var showDeletionError = false

    var body: some View {
        List {
            if servers.isEmpty {
                emptyState
            } else {
                ForEach(servers) { server in
                    serverRow(server)
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add server")
            }
        }
        .sheet(isPresented: $showAddServer) {
            ServerSetupView()
        }
        .sheet(item: $serverToEdit) { server in
            ServerSetupView(existingServer: server)
        }
        .alert("Remove Server?", isPresented: $showDeleteConfirmation, presenting: serverToDelete) { server in
            Button("Remove", role: .destructive) {
                Task { await deleteServer(server) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("This will remove \"\(server.name)\" and all its books from your library. Downloaded files will be kept.")
        }
        .alert("Could Not Remove Server", isPresented: $showDeletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("Add your Audiobookshelf server to stream your audiobook library.")
        } actions: {
            Button("Add Server") { showAddServer = true }
                .buttonStyle(.borderedProminent)
        }
        .listRowBackground(Color.clear)
    }

    private func serverRow(_ server: ABSServer) -> some View {
        NavigationLink(destination: ServerDetailView(server: server)) {
            HStack(spacing: LayoutDefaults.mediumSpacing) {
                // Status dot
                Circle()
                    .fill(server.isActive ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LayoutDefaults.tinySpacing) {
                    Text(server.name)
                        .font(.body)
                        .fontWeight(.medium)

                    Text(server.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let version = server.serverVersion {
                        Text("v\(version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if let syncDate = server.lastSyncDate {
                    Text(syncDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, LayoutDefaults.tinySpacing)
        }
        .accessibilityLabel("\(server.name), \(server.isActive ? "active" : "inactive")")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                serverToDelete = server
                showDeleteConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
            }

            Button {
                serverToEdit = server
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    // MARK: - Actions

    private func deleteServer(_ server: ABSServer) async {
        do {
            try await ServerRemovalService().removeServer(server, modelContext: modelContext)
        } catch {
            AppLogger.network.error("Failed to delete server: \(error.localizedDescription, privacy: .private)")
            deletionErrorMessage = error.localizedDescription
            showDeletionError = true
        }
    }
}

#Preview {
    NavigationStack {
        ServerListView()
    }
    .modelContainer(for: [ABSServer.self, Book.self, Folder.self], inMemory: true)
}
