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
        case synced(libraryId: String, libraryName: String)
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
            do {
                try await AudiobookshelfAuth.shared.deleteToken(for: server.normalizedURL)
            } catch {
                AppLogger.network.error("Failed to delete expired token from Keychain: \(error.localizedDescription, privacy: .private)")
            }
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

    static func syncPreferredLibrary(for server: ABSServerSnapshot, container: ModelContainer) async -> RemoteLibraryServerSyncResult {
        do {
            let tokenValid = try await validateServerAccess(for: server, container: container)
            guard tokenValid else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoToken)
            }

            let libraries = try await fetchLibraries(for: server)
            guard !libraries.isEmpty else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoLibraries)
            }

            let preferredLibrary = libraries.first(where: { $0.id == server.defaultLibraryId }) ?? libraries[0]
            var page = 0
            var fetchedCount = 0

            while true {
                let result = try await fetchAndMergeLibraryPage(
                    for: server,
                    libraryId: preferredLibrary.id,
                    page: page,
                    container: container
                )
                await BackgroundRemoteCoverArtService.shared.enqueue(requests: result.coverArtRequests, container: container)
                fetchedCount += result.response.results.count

                if result.response.results.isEmpty || fetchedCount >= result.response.total {
                    break
                }

                page += 1
            }

            try persistLastSyncDate(forServerId: server.id, container: container)
            return RemoteLibraryServerSyncResult(
                outcome: .synced(libraryId: preferredLibrary.id, libraryName: preferredLibrary.name)
            )
        } catch {
            return RemoteLibraryServerSyncResult(outcome: .failed(message: error.localizedDescription))
        }
    }

    private static func mergeIntoStore(
        items: [ABSLibraryItem],
        server: ABSServerSnapshot,
        container: ModelContainer
    ) throws -> [RemoteCoverArtRequest] {
        let serverId = server.id
        let serverURL = server.normalizedURL
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.serverId == serverId })
        let existingBooks = try context.fetch(descriptor)
        let existingByRemoteId = Dictionary(uniqueKeysWithValues: existingBooks.compactMap { book -> (String, Book)? in
            guard let remoteItemId = book.remoteItemId else { return nil }
            return (remoteItemId, book)
        })
        let unfiledFolder = try FolderService.resolveUnfiledFolder(in: context)

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
                updateCount += 1
            } else {
                let book = Book(
                    title: item.title,
                    author: item.authorName,
                    duration: duration,
                    folder: unfiledFolder,
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

#if DEBUG
    @MainActor
    static func syncPreferredLibrary(
        for server: ABSServerSnapshot,
        container: ModelContainer,
        validateServerAccess: @escaping @Sendable (ABSServerSnapshot, ModelContainer) async throws -> Bool,
        fetchLibraries: @escaping @Sendable (ABSServerSnapshot) async throws -> [ABSLibrary],
        fetchAndMergeLibraryPage: @escaping @Sendable (ABSServerSnapshot, String, Int, ModelContainer) async throws -> RemoteLibraryPageSyncResult,
        enqueueCoverArtRequests: @escaping @Sendable ([RemoteCoverArtRequest], ModelContainer) async -> Void,
        persistLastSyncDate: @escaping @Sendable (UUID, ModelContainer) throws -> Void
    ) async -> RemoteLibraryServerSyncResult {
        do {
            let tokenValid = try await validateServerAccess(server, container)
            guard tokenValid else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoToken)
            }

            let libraries = try await fetchLibraries(server)
            guard !libraries.isEmpty else {
                return RemoteLibraryServerSyncResult(outcome: .skippedNoLibraries)
            }

            let preferredLibrary = libraries.first(where: { $0.id == server.defaultLibraryId }) ?? libraries[0]
            var page = 0
            var fetchedCount = 0

            while true {
                let result = try await fetchAndMergeLibraryPage(server, preferredLibrary.id, page, container)
                await enqueueCoverArtRequests(result.coverArtRequests, container)
                fetchedCount += result.response.results.count

                if result.response.results.isEmpty || fetchedCount >= result.response.total {
                    break
                }

                page += 1
            }

            try persistLastSyncDate(server.id, container)
            return RemoteLibraryServerSyncResult(outcome: .synced(libraryId: preferredLibrary.id, libraryName: preferredLibrary.name))
        } catch {
            return RemoteLibraryServerSyncResult(outcome: .failed(message: error.localizedDescription))
        }
    }
#endif
}
