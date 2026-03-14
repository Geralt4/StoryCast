import Foundation
import SwiftData
import os

@MainActor
struct ServerRemovalService {
    typealias RemoteBookRemoval = @Sendable (ABSServerSnapshot, ModelContainer) async throws -> Void
    typealias LoadToken = @Sendable (String) async -> String?
    typealias DeleteToken = @Sendable (String) async throws -> Void
    typealias SaveToken = @Sendable (String, String) async throws -> Void
    typealias PersistServerDeletion = @Sendable (UUID, ModelContext) throws -> Void

    enum RemovalError: LocalizedError {
        case remoteCleanupFailed(underlying: Error)
        case tokenDeletionFailed(underlying: Error)
        case persistenceFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .remoteCleanupFailed(let underlying):
                return "Failed to clean up remote books: \(underlying.localizedDescription)"
            case .tokenDeletionFailed(let underlying):
                return "Failed to remove the saved login token: \(underlying.localizedDescription)"
            case .persistenceFailed(let underlying):
                return "Failed to remove the server from local storage: \(underlying.localizedDescription)"
            }
        }
    }

    private let remoteBookRemoval: RemoteBookRemoval
    private let loadToken: LoadToken
    private let deleteToken: DeleteToken
    private let saveToken: SaveToken
    private let persistServerDeletion: PersistServerDeletion

    init(
        remoteBookRemoval: @escaping RemoteBookRemoval = { snapshot, container in
            try await RemoteLibraryService.shared.removeRemoteBooks(for: snapshot, container: container)
        },
        loadToken: @escaping LoadToken = { serverURL in
            AudiobookshelfAuth.shared.token(for: serverURL)
        },
        deleteToken: @escaping DeleteToken = { serverURL in
            try AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        },
        saveToken: @escaping SaveToken = { token, serverURL in
            try AudiobookshelfAuth.shared.saveToken(token, for: serverURL)
        },
        persistServerDeletion: @escaping PersistServerDeletion = { serverId, modelContext in
            let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
            guard let server = try modelContext.fetch(descriptor).first else { return }
            modelContext.delete(server)
            try modelContext.save()
        }
    ) {
        self.remoteBookRemoval = remoteBookRemoval
        self.loadToken = loadToken
        self.deleteToken = deleteToken
        self.saveToken = saveToken
        self.persistServerDeletion = persistServerDeletion
    }

    func removeServer(_ server: ABSServer, modelContext: ModelContext) async throws {
        let serverURL = server.normalizedURL
        let existingToken = await loadToken(serverURL)

        do {
            try await remoteBookRemoval(server.snapshot(), modelContext.container)
        } catch {
            throw RemovalError.remoteCleanupFailed(underlying: error)
        }

        do {
            if existingToken != nil {
                try await deleteToken(serverURL)
            }
        } catch {
            throw RemovalError.tokenDeletionFailed(underlying: error)
        }

        do {
            try persistServerDeletion(server.id, modelContext)
        } catch {
            modelContext.rollback()
            if let existingToken {
                do {
                    try await saveToken(existingToken, serverURL)
                } catch {
                    AppLogger.network.warning("Failed to restore token after server removal error: \(error.localizedDescription, privacy: .private)")
                }
            }
            throw RemovalError.persistenceFailed(underlying: error)
        }
    }
}
