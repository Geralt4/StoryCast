import Foundation
import SwiftData
import Combine
import os

/// Tracks the active Audiobookshelf server and its library list for the Settings screens, and removes a server's books. Syncing books into the Library is done by `RemoteLibrarySyncEngine`.
@MainActor
final class RemoteLibraryService: ObservableObject {
    static let shared = RemoteLibraryService()

    // MARK: - Published State

    @Published private(set) var libraries: [ABSLibrary] = []
    @Published private(set) var error: Error?
    @Published private(set) var activeServer: ABSServer?

    // MARK: - Private

    private var currentActivationId: UUID?

    private init() {}

    // MARK: - Server Activation

    /// Validates the server token; returns true if valid, false if re-login needed.
    /// Uses operation ID to abort stale activations on rapid server switches.
    func activateServer(_ server: ABSServer, container: ModelContainer) async -> Bool {
        let activationId = UUID()
        currentActivationId = activationId

        do {
            let tokenValid = try await RemoteLibrarySyncEngine.validateServerAccess(for: server.snapshot(), container: container)

            // Only set as active if this is still the current operation
            guard currentActivationId == activationId else {
                AppLogger.network.debug("Activation aborted for \(server.name, privacy: .private) (superseded)")
                return false
            }

            activeServer = server
            guard tokenValid else {
                return false
            }

            AppLogger.network.info("Server \(server.name, privacy: .private) activated")
            return true
        } catch {
            guard currentActivationId == activationId else { return false }
            self.error = error
            AppLogger.network.error("Server activation failed for \(server.name, privacy: .private): \(error.localizedDescription, privacy: .private)")
            activeServer = server
            return false
        }
    }

    // MARK: - Library Fetching

    /// Fetches all book libraries from the active server.
    func fetchLibraries() async {
        guard let server = activeServer else {
            error = APIError.noActiveServer
            return
        }

        error = nil

        do {
            libraries = try await RemoteLibrarySyncEngine.fetchLibraries(for: server.snapshot())
            AppLogger.network.info("Fetched \(self.libraries.count) libraries from \(server.name, privacy: .private)")
        } catch {
            self.error = error
            AppLogger.network.error("Failed to fetch libraries: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Cleanup

    enum RemoteBookRemovalError: LocalizedError {
        case cleanupFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .cleanupFailed(let underlying):
                return "Failed to remove remote books: \(underlying.localizedDescription)"
            }
        }
    }

    /// Removes all remote books for the given server from the SwiftData store.
    func removeRemoteBooks(for snapshot: ABSServerSnapshot, container: ModelContainer) async throws {
        let serverId = snapshot.id
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<Book>(
                predicate: #Predicate { $0.serverId == serverId }
            )
            let books = try context.fetch(descriptor)
            let bookIds = Set(books.map(\.id))

            await BackgroundRemoteCoverArtService.shared.cancelTasks(for: bookIds)
            DownloadManager.shared.cancelDownloads(for: bookIds)

            for book in books {
                try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: nil, in: context)
            }
            try context.save()
            StorageCleanupCoordinator.drainPendingCleanup(in: context)

            AppLogger.network.info("Removed \(books.count) remote books for server \(snapshot.name, privacy: .private)")
        } catch {
            context.rollback()
            AppLogger.network.error("Failed to remove remote books: \(error.localizedDescription, privacy: .private)")
            throw RemoteBookRemovalError.cleanupFailed(underlying: error)
        }

        if activeServer?.id == snapshot.id {
            activeServer = nil
            libraries = []
        }
    }

#if DEBUG
    func debugResetUIState() {
        activeServer = nil
        libraries = []
        error = nil
        currentActivationId = nil
        Task {
            await BackgroundRemoteCoverArtService.shared.debugResetState()
        }
    }

    func debugSetActiveServer(_ server: ABSServer?) {
        activeServer = server
    }
#endif
}
