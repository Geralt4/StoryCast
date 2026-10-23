import Foundation
import SwiftData
import os

struct RemoteCoverArtRequest {
    let bookId: UUID
    let serverId: UUID
    let itemId: String
    let serverURL: String
}

struct RemoteLibraryPageSyncResult {
    let response: ABSLibraryItemsResponse
    let coverArtRequests: [RemoteCoverArtRequest]
}

struct RemoteLibraryServerSyncResult: Sendable {
    enum Outcome: Sendable {
        case synced(libraryNames: [String])
        case skippedNoToken
        case skippedNoLibraries
        case failed(message: String)
    }

    let outcome: Outcome
}

@MainActor
enum RemoteLibrarySyncEngine {
    static func validateServerAccess(for server: ABSServerSnapshot, container: ModelContainer) async throws -> Bool {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            return false
        }

        do {
            _ = try await AudiobookshelfAPI.shared.authorize(baseURL: server.normalizedURL, token: token)

            if server.defaultLibraryId == nil {
                let libraries = try await AudiobookshelfAPI.shared.fetchLibraries(baseURL: server.normalizedURL, token: token)
                if let firstLibrary = libraries.first {
                    try persistDefaultLibraryId(firstLibrary.id, forServerId: server.id, container: container)
                }
            }

            return true
        } catch APIError.unauthorized {
            return false
        }
    }

    static func fetchLibraries(for server: ABSServerSnapshot) async throws -> [ABSLibrary] {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }

        return try await AudiobookshelfAPI.shared.fetchLibraries(baseURL: server.normalizedURL, token: token)
    }

    static func fetchAndMergeLibraryPage(
        for server: ABSServerSnapshot,
        libraryId: String,
        page: Int,
        container: ModelContainer
    ) async throws -> RemoteLibraryPageSyncResult {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }

        let response = try await AudiobookshelfAPI.shared.fetchLibraryItems(
            baseURL: server.normalizedURL,
            token: token,
            libraryId: libraryId,
            page: page
        )
        let coverArtRequests = try mergeIntoStore(items: response.results, server: server, container: container)
        return RemoteLibraryPageSyncResult(response: response, coverArtRequests: coverArtRequests)
    }

    /// Internal (not private) so tests can merge fixture items without network or Keychain.
    static func mergeIntoStore(
        items: [ABSLibraryItem],
        server: ABSServerSnapshot,
        container: ModelContainer
    ) throws -> [RemoteCoverArtRequest] {
        let serverId = server.id
        let serverURL = server.normalizedURL
        let context = ModelContext(container)
        var serverDescriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
        serverDescriptor.fetchLimit = 1
        guard let persistedServer = try context.fetch(serverDescriptor).first, persistedServer.isActive else {
            return []
        }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.serverId == serverId })
        let existingBooks = try context.fetch(descriptor)
        var existingByRemoteId: [String: Book] = [:]
        for book in existingBooks {
            guard let remoteItemId = book.remoteItemId else { continue }
            // Duplicate remote IDs can exist because library dedup skips
            // remote books. First-wins avoids crashing Dictionary(uniqueKeys:).
            if existingByRemoteId[remoteItemId] == nil {
                existingByRemoteId[remoteItemId] = book
            }
        }
        let serverFolder = try FolderService.resolveServerFolder(serverId: serverId, name: persistedServer.name, in: context)

        var insertCount = 0
        var updateCount = 0
        var newRemoteItemIds: Set<String> = []

        for item in items {
            let duration = max(item.duration, 1.0)
            if let existing = existingByRemoteId[item.id] {
                existing.title = item.title
                existing.author = item.authorName
                existing.duration = duration
                existing.lastSyncDate = Date()
                existing.updateSearchFields()
                // Move books out of Unfiled (or a missing folder) once, but keep
                // any folder the user chose themselves.
                if existing.folder == nil || existing.folder?.isSystem == true {
                    existing.folder = serverFolder
                }
                updateCount += 1
            } else {
                let book = Book(
                    title: item.title,
                    author: item.authorName,
                    duration: duration,
                    folder: serverFolder,
                    isRemote: true,
                    remoteItemId: item.id,
                    remoteLibraryId: item.libraryId,
                    serverId: serverId
                )
                context.insert(book)
                insertCount += 1
                newRemoteItemIds.insert(item.id)
            }
        }

        guard insertCount > 0 || updateCount > 0 else {
            return []
        }

        try context.save()
        AppLogger.network.info("Merged remote books: \(insertCount) inserted, \(updateCount) updated")

        let allBooks = try context.fetch(descriptor)
        return allBooks.compactMap { book in
            guard let remoteItemId = book.remoteItemId,
                  let bookServerId = book.serverId,
                  newRemoteItemIds.contains(remoteItemId),
                  book.coverArtFileName == nil else {
                return nil
            }

            return RemoteCoverArtRequest(
                bookId: book.id,
                serverId: bookServerId,
                itemId: remoteItemId,
                serverURL: serverURL
            )
        }
    }

    private static func persistDefaultLibraryId(_ libraryId: String, forServerId serverId: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
        if let persistedServer = try context.fetch(descriptor).first {
            persistedServer.defaultLibraryId = libraryId
            try context.save()
        }
    }

    private static func persistLastSyncDate(forServerId serverId: UUID, container: ModelContainer) throws {
        let syncDate = Date()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
        if let persistedServer = try context.fetch(descriptor).first {
            persistedServer.lastSyncDate = syncDate
            try context.save()
        }
    }

    /// Syncs every book library on the server into the local store. Each book
    /// lands in the server's own folder (see `FolderService.resolveServerFolder`).
    /// The steps are injectable so tests can drive the real loop without network or Keychain.
    static func syncServer(
        for server: ABSServerSnapshot,
        container: ModelContainer,
        validateServerAccess: @escaping @Sendable (ABSServerSnapshot, ModelContainer) async throws -> Bool = { server, container in
            try await RemoteLibrarySyncEngine.validateServerAccess(for: server, container: container)
        },
        fetchLibraries: @escaping @Sendable (ABSServerSnapshot) async throws -> [ABSLibrary] = { server in
            try await RemoteLibrarySyncEngine.fetchLibraries(for: server)
        },
        fetchAndMergeLibraryPage: @escaping @Sendable (ABSServerSnapshot, String, Int, ModelContainer) async throws -> RemoteLibraryPageSyncResult = { server, libraryId, page, container in
            try await RemoteLibrarySyncEngine.fetchAndMergeLibraryPage(for: server, libraryId: libraryId, page: page, container: container)
        },
        enqueueCoverArtRequests: @escaping @Sendable ([RemoteCoverArtRequest], ModelContainer) async -> Void = { requests, container in
            await BackgroundRemoteCoverArtService.shared.enqueue(requests: requests, container: container)
        },
        persistLastSyncDate: @escaping @Sendable (UUID, ModelContainer) async throws -> Void = { serverId, container in
            try await MainActor.run { try RemoteLibrarySyncEngine.persistLastSyncDate(forServerId: serverId, container: container) }
        }
    ) async -> RemoteLibraryServerSyncResult {
        do {
            let tokenValid = try await validateServerAccess(server, container)
            guard tokenValid else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoToken)
            }

            let libraries = try await fetchLibraries(server).filter { $0.mediaType == "book" }
            guard !libraries.isEmpty else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoLibraries)
            }

            for library in libraries {
                var page = 0
                var fetchedCount = 0

                while true {
                    let result = try await fetchAndMergeLibraryPage(server, library.id, page, container)
                    await enqueueCoverArtRequests(result.coverArtRequests, container)
                    fetchedCount += result.response.results.count

                    if result.response.results.isEmpty || fetchedCount >= result.response.total {
                        break
                    }

                    page += 1
                }
            }

            try await persistLastSyncDate(server.id, container)
            return RemoteLibraryServerSyncResult(outcome: .synced(libraryNames: libraries.map(\.name)))
        } catch {
            return RemoteLibraryServerSyncResult(outcome: .failed(message: error.localizedDescription))
        }
    }
}
