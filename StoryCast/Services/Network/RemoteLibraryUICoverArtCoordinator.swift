import Foundation
import SwiftData
import os

// MARK: - Cover Art Failure

/// Tracks a failed cover art download for a specific book, including retry state.
struct CoverArtFailure: Sendable {
    let bookId: UUID
    let serverId: UUID
    var compoundKey: String { "\(serverId.uuidString)_\(bookId.uuidString)" }
    let itemId: String
    let errorDescription: String
    let timestamp: Date
    let retryCount: Int

    static let maxRetries: Int = 3

    /// Exponential backoff delay (seconds): 2s → 4s → 8s.
    var backoffDelay: TimeInterval { pow(2.0, Double(retryCount)) }

    var isExhausted: Bool { retryCount >= Self.maxRetries }

    init(bookId: UUID, serverId: UUID, itemId: String, error: Error, timestamp: Date, retryCount: Int) {
        self.bookId = bookId
        self.serverId = serverId
        self.itemId = itemId
        self.errorDescription = error.localizedDescription
        self.timestamp = timestamp
        self.retryCount = retryCount
    }
}

@MainActor
final class RemoteLibraryUICoverArtCoordinator {
    static let shared = RemoteLibraryUICoverArtCoordinator()

    var onFailuresChanged: (([String: CoverArtFailure]) -> Void)?

    private(set) var failures: [String: CoverArtFailure] = [:] {
        didSet { onFailuresChanged?(failures) }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func enqueue(requests: [RemoteCoverArtRequest], container: ModelContainer) {
        for request in requests {
            let bookId = request.bookId
            tasks[bookId]?.cancel()
            tasks[bookId] = Task(priority: .utility) {
                await self.downloadAndSaveCoverArt(request: request, container: container)
                _ = await MainActor.run {
                    self.tasks.removeValue(forKey: bookId)
                }
            }
        }
    }

    func retryCoverArtDownload(for bookId: UUID, activeServer: ABSServer?, container: ModelContainer) {
        guard let server = activeServer else { return }

        let compoundKey = "\(server.id.uuidString)_\(bookId.uuidString)"
        guard let failure = failures[compoundKey] else { return }

        failures.removeValue(forKey: compoundKey)

        let request = RemoteCoverArtRequest(
            bookId: bookId,
            serverId: server.id,
            itemId: failure.itemId,
            serverURL: server.normalizedURL
        )

        tasks[bookId]?.cancel()
        tasks[bookId] = Task(priority: .utility) {
            await self.downloadAndSaveCoverArt(request: request, container: container)
            _ = await MainActor.run {
                self.tasks.removeValue(forKey: bookId)
            }
        }
    }

    func retryAllCoverArtDownloads(activeServer: ABSServer?, container: ModelContainer) {
        let bookIds = failures.keys.compactMap { compoundKey -> UUID? in
            let components = compoundKey.split(separator: "_", maxSplits: 1)
            guard components.count == 2 else { return nil }
            return UUID(uuidString: String(components[1]))
        }

        for bookId in bookIds {
            retryCoverArtDownload(for: bookId, activeServer: activeServer, container: container)
        }
    }

    func cancelAllCoverArtDownloads() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        AppLogger.network.debug("Cancelled all cover art download tasks")
    }

    func cancelCoverArtDownloads(for bookIds: Set<UUID>) {
        for bookId in bookIds {
            if let task = tasks.removeValue(forKey: bookId) {
                task.cancel()
            }
        }

        if !bookIds.isEmpty {
            AppLogger.network.debug("Cancelled \(bookIds.count) scoped cover art download tasks")
        }
    }

    private func downloadAndSaveCoverArt(request: RemoteCoverArtRequest, container: ModelContainer) async {
        let compoundKey = "\(request.serverId.uuidString)_\(request.bookId.uuidString)"

        guard let token = await AudiobookshelfAuth.shared.token(for: request.serverURL) else { return }

        do {
            let data = try await AudiobookshelfAPI.shared.fetchCoverArt(
                baseURL: request.serverURL,
                token: token,
                itemId: request.itemId
            )
            _ = try await RemoteCoverArtPersistence.persistCoverArt(data, for: request, container: container)
            _ = await MainActor.run {
                self.failures.removeValue(forKey: compoundKey)
            }
        } catch {
            AppLogger.network.debug("Cover art download failed for \(request.itemId, privacy: .private): \(error.localizedDescription, privacy: .private)")

            await MainActor.run {
                let previousRetries = self.failures[compoundKey]?.retryCount ?? 0
                let failure = CoverArtFailure(
                    bookId: request.bookId,
                    serverId: request.serverId,
                    itemId: request.itemId,
                    error: error,
                    timestamp: Date(),
                    retryCount: previousRetries + 1
                )
                self.failures[compoundKey] = failure

                if !failure.isExhausted {
                    let delay = failure.backoffDelay
                    let bookId = request.bookId
                    self.tasks[bookId]?.cancel()
                    self.tasks[bookId] = Task(priority: .utility) {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await self.downloadAndSaveCoverArt(request: request, container: container)
                        _ = await MainActor.run { self.tasks.removeValue(forKey: bookId) }
                    }
                }
            }
        }
    }

#if DEBUG
    var debugTaskCount: Int { tasks.count }

    func debugRegisterTask(_ task: Task<Void, Never>, for bookId: UUID) {
        tasks[bookId] = task
    }

    func debugRecordFailure(
        bookId: UUID,
        serverId: UUID,
        itemId: String,
        retryCount: Int = 1,
        error: Error = NSError(domain: "RemoteLibraryServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected cover art failure"])
    ) {
        let failure = CoverArtFailure(
            bookId: bookId,
            serverId: serverId,
            itemId: itemId,
            error: error,
            timestamp: Date(),
            retryCount: retryCount
        )
        failures[failure.compoundKey] = failure
    }

    func debugResetState() {
        cancelAllCoverArtDownloads()
        failures.removeAll()
    }
#endif
}
