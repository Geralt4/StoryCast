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

    /// Maps a bookId to the currently-tracked task along with the
    /// "generation" (monotonic counter) of the task that installed the entry.
    /// We use a generation counter instead of `Task` identity because `Task`
    /// is a value type in Swift 6, so reference equality (`===`) doesn't work.
    /// Every time we install a new task (whether via `enqueue`, `retry…`, or
    /// the inner retry-after-failure path) the counter is bumped, and the
    /// cleanup code only removes the entry if the current generation still
    /// matches the one the task captured at install time.
    private struct TaskSlot {
        var task: Task<Void, Never>
        var generation: UInt64
    }
    private var tasks: [UUID: TaskSlot] = [:]
    private var nextGeneration: UInt64 = 0

    private init() {}

    func enqueue(requests: [RemoteCoverArtRequest], container: ModelContainer) {
        for request in requests {
            let bookId = request.bookId
            tasks[bookId]?.task.cancel()
            let generation = allocateGeneration(for: bookId)
            let task = Task(priority: .utility) { [weak self] in
                await self?.downloadAndSaveCoverArt(
                    request: request,
                    container: container,
                    bookId: bookId
                )
                // Only clear the entry if it's still the generation we
                // installed. The error handler may have installed a newer
                // (retry) task under the same bookId — in that case we
                // must not evict it.
                await MainActor.run {
                    guard let self else { return }
                    if let slot = self.tasks[bookId], slot.generation == generation {
                        self.tasks.removeValue(forKey: bookId)
                    }
                }
            }
            tasks[bookId] = TaskSlot(task: task, generation: generation)
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

        tasks[bookId]?.task.cancel()
        let generation = allocateGeneration(for: bookId)
        let task = Task(priority: .utility) { [weak self] in
            await self?.downloadAndSaveCoverArt(
                request: request,
                container: container,
                bookId: bookId
            )
            await MainActor.run {
                guard let self else { return }
                if let slot = self.tasks[bookId], slot.generation == generation {
                    self.tasks.removeValue(forKey: bookId)
                }
            }
        }
        tasks[bookId] = TaskSlot(task: task, generation: generation)
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
        // Snapshot the values before mutating the dict to avoid undefined
        // behavior from mutating-while-iterating.
        for slot in Array(tasks.values) {
            slot.task.cancel()
        }
        tasks.removeAll()
        AppLogger.network.debug("Cancelled all cover art download tasks")
    }

    func cancelCoverArtDownloads(for bookIds: Set<UUID>) {
        for bookId in bookIds {
            if let slot = tasks.removeValue(forKey: bookId) {
                slot.task.cancel()
            }
        }

        if !bookIds.isEmpty {
            AppLogger.network.debug("Cancelled \(bookIds.count) scoped cover art download tasks")
        }
    }

    /// Allocates a fresh generation number and bumps the global counter.
    /// Wrapping the counter in a helper keeps the bookkeeping consistent
    /// at every call site that installs a task.
    private func allocateGeneration(for bookId: UUID) -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    private func downloadAndSaveCoverArt(
        request: RemoteCoverArtRequest,
        container: ModelContainer,
        bookId: UUID
    ) async {
        let compoundKey = "\(request.serverId.uuidString)_\(request.bookId.uuidString)"

        guard !Task.isCancelled else { return }
        guard let token = await AudiobookshelfAuth.shared.token(for: request.serverURL) else { return }

        do {
            let data = try await AudiobookshelfAPI.shared.fetchCoverArt(
                baseURL: request.serverURL,
                token: token,
                itemId: request.itemId
            )
            try Task.checkCancellation()
            _ = try await RemoteCoverArtPersistence.persistCoverArt(data, for: request, container: container)
            _ = await MainActor.run {
                self.failures.removeValue(forKey: compoundKey)
            }
        } catch is CancellationError {
            return
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

                guard !failure.isExhausted else { return }
                let delay = failure.backoffDelay
                let request = request
                let container = container
                // Install a retry task. We allocate a fresh generation so
                // the outer task (whose captured generation is now stale)
                // will not evict the retry task when it completes.
                let generation = self.allocateGeneration(for: request.bookId)
                let task = Task(priority: .utility) { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    await self?.downloadAndSaveCoverArt(
                        request: request,
                        container: container,
                        bookId: bookId
                    )
                    await MainActor.run {
                        guard let self else { return }
                        if let slot = self.tasks[bookId], slot.generation == generation {
                            self.tasks.removeValue(forKey: bookId)
                        }
                    }
                }
                self.tasks[bookId] = TaskSlot(task: task, generation: generation)
            }
        }
    }

#if DEBUG
    var debugTaskCount: Int { tasks.count }

    func debugRegisterTask(_ task: Task<Void, Never>, for bookId: UUID) {
        tasks[bookId] = TaskSlot(task: task, generation: allocateGeneration(for: bookId))
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
