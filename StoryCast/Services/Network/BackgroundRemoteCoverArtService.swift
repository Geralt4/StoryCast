import Foundation
import SwiftData
import os

enum RemoteCoverArtPersistence {
    @MainActor
    static func persistCoverArt(_ data: Data, for request: RemoteCoverArtRequest, container: ModelContainer) async throws -> Bool {
        let bookId = request.bookId
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookId })
        descriptor.fetchLimit = 1

        guard let book = try context.fetch(descriptor).first else {
            return false
        }

        let previousFileName = book.coverArtFileName
        guard let fileName = try await StorageManager.shared.saveCoverArt(data, for: request.bookId, location: .remoteCache) else {
            return false
        }

        book.coverArtFileName = fileName

        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            book.coverArtFileName = previousFileName

            if previousFileName != fileName {
                await StorageManager.shared.deleteCoverArt(fileName: fileName, isRemote: true)
            }

            throw error
        }
    }
}

actor BackgroundRemoteCoverArtService {
    typealias TokenProvider = @Sendable (String) async -> String?
    typealias CoverArtFetcher = @Sendable (String, String, String) async throws -> Data
    typealias CoverArtPersister = @Sendable (Data, RemoteCoverArtRequest, ModelContainer) async throws -> Bool

    static let shared = BackgroundRemoteCoverArtService()

    private let tokenProvider: TokenProvider
    private let coverArtFetcher: CoverArtFetcher
    private let coverArtPersister: CoverArtPersister
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        tokenProvider: @escaping TokenProvider = { serverURL in
            AudiobookshelfAuth.shared.token(for: serverURL)
        },
        coverArtFetcher: @escaping CoverArtFetcher = { baseURL, token, itemId in
            try await AudiobookshelfAPI.shared.fetchCoverArt(baseURL: baseURL, token: token, itemId: itemId)
        },
        coverArtPersister: @escaping CoverArtPersister = { data, request, container in
            try await RemoteCoverArtPersistence.persistCoverArt(data, for: request, container: container)
        }
    ) {
        self.tokenProvider = tokenProvider
        self.coverArtFetcher = coverArtFetcher
        self.coverArtPersister = coverArtPersister
    }

    func enqueue(requests: [RemoteCoverArtRequest], container: ModelContainer) {
        for request in requests {
            guard tasks[request.bookId] == nil else { continue }

            tasks[request.bookId] = Task(priority: .utility) {
                await self.process(request: request, container: container)
            }
        }
    }

    func cancelTasks(for bookIds: Set<UUID>) {
        for bookId in bookIds {
            if let task = tasks.removeValue(forKey: bookId) {
                task.cancel()
            }
        }
    }

    private func process(request: RemoteCoverArtRequest, container: ModelContainer) async {
        defer { tasks.removeValue(forKey: request.bookId) }

        var attempt = 0
        let maxAttempts = 3

        while attempt < maxAttempts {
            do {
                try Task.checkCancellation()

                guard let token = await tokenProvider(request.serverURL) else {
                    throw APIError.tokenMissing
                }

                let data = try await coverArtFetcher(request.serverURL, token, request.itemId)
                _ = try await coverArtPersister(data, request, container)
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                guard attempt < maxAttempts else {
                    AppLogger.network.debug(
                        "Background cover art sync failed for \(request.itemId, privacy: .private): \(error.localizedDescription, privacy: .private)"
                    )
                    return
                }

                let delay = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

#if DEBUG
    func debugRegisterTask(_ task: Task<Void, Never>, for bookId: UUID) {
        if let existingTask = tasks.updateValue(task, forKey: bookId) {
            existingTask.cancel()
        }
    }

    func debugTaskCount() -> Int {
        tasks.count
    }

    func debugResetState() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
#endif
}
