import Foundation
import SwiftData
import os

@MainActor
struct ServerRemovalService {
    typealias RemoteBookRemoval = @Sendable (ABSServerSnapshot, ModelContainer) async throws -> Void
    typealias DeleteToken = @Sendable (String) async throws -> Void
    typealias PersistFinalDeletion = @Sendable (UUID, ModelContainer) async throws -> Void

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
    private let deleteToken: DeleteToken
    private let persistFinalDeletion: PersistFinalDeletion

    init(
        remoteBookRemoval: @escaping RemoteBookRemoval = { snapshot, container in
            try await RemoteLibraryService.shared.removeRemoteBooks(for: snapshot, container: container)
        },
        deleteToken: @escaping DeleteToken = { serverURL in
            try AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        },
        persistFinalDeletion: @escaping PersistFinalDeletion = { serverId, container in
            try await MainActor.run {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                guard let server = try context.fetch(descriptor).first else { return }
                let books = try context.fetch(FetchDescriptor<Book>(
                    predicate: #Predicate { $0.serverId == serverId }
                ))
                for book in books {
                    try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: nil, in: context)
                }
                let journalDescriptor = FetchDescriptor<ServerRemovalJournalEntry>(
                    predicate: #Predicate { $0.serverID == serverId }
                )
                for entry in try context.fetch(journalDescriptor) {
                    context.delete(entry)
                }
                context.delete(server)
                try context.save()
                StorageCleanupCoordinator.drainPendingCleanup(in: context)
            }
        }
    ) {
        self.remoteBookRemoval = remoteBookRemoval
        self.deleteToken = deleteToken
        self.persistFinalDeletion = persistFinalDeletion
    }

    func removeServer(_ server: ABSServer, modelContext: ModelContext) async throws {
        let container = modelContext.container
        let serverID = server.id
        let serverURL = server.normalizedURL

        let existingJournal = try? modelContext.fetch(FetchDescriptor<ServerRemovalJournalEntry>(
            predicate: #Predicate { $0.serverID == serverID }
        )).first

        if existingJournal == nil {
            do {
                let entry = ServerRemovalJournalEntry(
                    serverID: serverID,
                    normalizedURL: serverURL,
                    displayName: server.name,
                    previousIsActive: server.isActive,
                    phaseRaw: "prepared"
                )
                modelContext.insert(entry)
                server.isActive = false
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw RemovalError.persistenceFailed(underlying: error)
            }
        }

        do {
            try await deleteToken(serverURL)
        } catch {
            throw RemovalError.tokenDeletionFailed(underlying: error)
        }

        if let journal = try? modelContext.fetch(FetchDescriptor<ServerRemovalJournalEntry>(
            predicate: #Predicate { $0.serverID == serverID }
        )).first {
            journal.phaseRaw = "credentialRemoved"
            journal.updatedAt = Date()
            try? modelContext.save()
        }

        do {
            try await persistFinalDeletion(serverID, container)
        } catch {
            throw RemovalError.persistenceFailed(underlying: error)
        }
    }

    static func resumePendingRemovals(container: ModelContainer) async {
        let context = ModelContext(container)
        let entries = (try? context.fetch(FetchDescriptor<ServerRemovalJournalEntry>())) ?? []
        for entry in entries {
            let serverID = entry.serverID
            do {
                try await Self.resumeRemoval(serverID: serverID, container: container)
            } catch {
                AppLogger.network.error("Failed to resume server removal for \(entry.displayName): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private static func resumeRemoval(serverID: UUID, container: ModelContainer) async throws {
        let service = ServerRemovalService()
        let serverContext = ModelContext(container)
        guard let server = try? serverContext.fetch(FetchDescriptor<ABSServer>(
            predicate: #Predicate { $0.id == serverID }
        )).first else {
            let cleanupContext = ModelContext(container)
            let journals = try cleanupContext.fetch(FetchDescriptor<ServerRemovalJournalEntry>(
                predicate: #Predicate { $0.serverID == serverID }
            ))
            for j in journals { cleanupContext.delete(j) }
            try cleanupContext.save()
            return
        }

        try await service.removeServer(server, modelContext: serverContext)
    }
}