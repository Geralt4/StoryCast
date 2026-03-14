import Foundation
import SwiftData
import Combine
import os

// MARK: - Cover Art Failure

/// Tracks a failed cover art download for a specific book, including retry state.
struct CoverArtFailure: Sendable {
    /// The SwiftData `Book.id` for the affected book.
    let bookId: UUID
    /// The server ID this failure is associated with.
    let serverId: UUID
    /// The compound key for this failure (serverId_bookId).
    var compoundKey: String { "\(serverId.uuidString)_\(bookId.uuidString)" }
    /// The Audiobookshelf item ID used to fetch cover art.
    let itemId: String
    /// Description of the error that caused the last download failure.
    let errorDescription: String
    /// When the last failure occurred.
    let timestamp: Date
    /// How many times a download has been attempted and failed (1 on first failure).
    let retryCount: Int

    /// Maximum number of attempts before giving up on automatic retries.
    static let maxRetries: Int = 3

    /// Exponential backoff delay (seconds) before the next auto-retry.
    /// Sequence: 2s → 4s → 8s.
    var backoffDelay: TimeInterval {
        pow(2.0, Double(retryCount))
    }

    /// True when no more automatic retries will be attempted.
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

/// Fetches and caches the remote Audiobookshelf library for a given server.
/// Merges remote items into the local SwiftData store as `Book` records with
/// `source == .remote`, so they appear alongside local books in the library.
@MainActor
final class RemoteLibraryService: ObservableObject {
    static let shared = RemoteLibraryService()
    private let uiCoverArtCoordinator: RemoteLibraryUICoverArtCoordinator

    // MARK: - Published State

    @Published private(set) var libraries: [ABSLibrary] = []
    @Published private(set) var remoteItems: [ABSLibraryItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: Error?
    @Published private(set) var activeServer: ABSServer?
    /// Books whose cover art download has failed, keyed by compound key `serverId_bookId`.
    @Published private(set) var coverArtFailures: [String: CoverArtFailure] = [:]

    // MARK: - Private

    private var currentPage: Int = 0
    private var totalItems: Int = 0
    private var selectedLibraryId: String?
    private var currentActivationId: UUID?

    private init() {
        let uiCoverArtCoordinator = RemoteLibraryUICoverArtCoordinator.shared
        self.uiCoverArtCoordinator = uiCoverArtCoordinator
        self.coverArtFailures = uiCoverArtCoordinator.failures
        self.uiCoverArtCoordinator.onFailuresChanged = { [weak self] failures in
            self?.coverArtFailures = failures
        }
    }

    // MARK: - Server Activation

    /// Sets the active server and validates the stored token.
    /// Returns `true` if the token is valid, `false` if re-login is needed.
    /// Uses an operation ID to detect and abort stale activations when servers change
    /// rapidly (e.g., user switches servers before the previous activation completes).
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

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            libraries = try await RemoteLibrarySyncEngine.fetchLibraries(for: server.snapshot())
            AppLogger.network.info("Fetched \(self.libraries.count) libraries from \(server.name, privacy: .private)")
        } catch {
            self.error = error
            AppLogger.network.error("Failed to fetch libraries: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Fetches the first page of items from the given library and resets pagination.
    func fetchItems(libraryId: String, container: ModelContainer) async {
        selectedLibraryId = libraryId
        currentPage = 0
        remoteItems = []
        await loadNextPage(container: container)
    }

    /// Loads the next page of items (for infinite scroll / pull-to-refresh).
    func loadNextPage(container: ModelContainer) async {
        guard let server = activeServer,
              let libraryId = selectedLibraryId else { return }

        // Don't load beyond the total.
        if currentPage > 0 && remoteItems.count >= totalItems { return }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let pageResult = try await RemoteLibrarySyncEngine.fetchAndMergeLibraryPage(
                for: server.snapshot(),
                libraryId: libraryId,
                page: currentPage,
                container: container
            )
            let response = pageResult.response
            totalItems = response.total
            remoteItems.append(contentsOf: response.results)
            currentPage += 1
            enqueueCoverArtDownloads(pageResult.coverArtRequests, container: container)

            AppLogger.network.info("Fetched page \(self.currentPage - 1): \(response.results.count) items (total \(response.total))")
        } catch {
            self.error = error
            AppLogger.network.error("Failed to fetch library items: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func enqueueCoverArtDownloads(_ requests: [RemoteCoverArtRequest], container: ModelContainer) {
        uiCoverArtCoordinator.enqueue(requests: requests, container: container)
    }

    func resolveUnfiledFolder(in context: ModelContext) throws -> Folder {
        // Use centralized FolderService to ensure atomic Unfiled folder resolution
        return try FolderService.resolveUnfiledFolder(in: context)
    }

    /// Manually retries a failed cover art download for the given book ID.
    /// Resets the retry counter so the exponential backoff sequence restarts.
    func retryCoverArtDownload(for bookId: UUID, container: ModelContainer) {
        uiCoverArtCoordinator.retryCoverArtDownload(for: bookId, activeServer: activeServer, container: container)
    }

    /// Retries all currently tracked cover art failures.
    func retryAllCoverArtDownloads(container: ModelContainer) {
        uiCoverArtCoordinator.retryAllCoverArtDownloads(activeServer: activeServer, container: container)
    }

    // MARK: - Cleanup

    /// Cancels all in-progress cover art download tasks.
    func cancelAllCoverArtDownloads() {
        uiCoverArtCoordinator.cancelAllCoverArtDownloads()
    }

    /// Cancels in-progress cover art download tasks for the supplied book IDs.
    func cancelCoverArtDownloads(for bookIds: Set<UUID>) {
        uiCoverArtCoordinator.cancelCoverArtDownloads(for: bookIds)
    }

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
            let assetReferences = books.map { book in
                (cachePath: book.localCachePath, coverArtFileName: book.coverArtFileName)
            }

            cancelCoverArtDownloads(for: bookIds)
            await BackgroundRemoteCoverArtService.shared.cancelTasks(for: bookIds)
            DownloadManager.shared.cancelDownloads(for: bookIds)

            for book in books {
                context.delete(book)
            }
            try context.save()

            for reference in assetReferences {
                if let cachePath = reference.cachePath {
                    await StorageManager.shared.deleteRemoteAudioCache(fileName: cachePath)
                }
                if let coverArtFileName = reference.coverArtFileName {
                    await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName, isRemote: true)
                }
            }

            AppLogger.network.info("Removed \(books.count) remote books for server \(snapshot.name, privacy: .private)")
        } catch {
            AppLogger.network.error("Failed to remove remote books: \(error.localizedDescription, privacy: .private)")
            throw RemoteBookRemovalError.cleanupFailed(underlying: error)
        }

        if activeServer?.id == snapshot.id {
            activeServer = nil
            libraries = []
            remoteItems = []
        }
    }

#if DEBUG
    var debugCoverArtTaskCount: Int { uiCoverArtCoordinator.debugTaskCount }

    func debugResetUIState() {
        activeServer = nil
        libraries = []
        remoteItems = []
        error = nil
        coverArtFailures.removeAll()
        currentPage = 0
        totalItems = 0
        selectedLibraryId = nil
        currentActivationId = nil
        cancelAllCoverArtDownloads()
        Task {
            await BackgroundRemoteCoverArtService.shared.debugResetState()
        }
    }

    func debugSetActiveServer(_ server: ABSServer?) {
        activeServer = server
    }

    func debugRecordCoverArtFailure(
        bookId: UUID,
        serverId: UUID,
        itemId: String,
        retryCount: Int = 1,
        error: Error = NSError(domain: "RemoteLibraryServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected cover art failure"])
    ) {
        uiCoverArtCoordinator.debugRecordFailure(
            bookId: bookId,
            serverId: serverId,
            itemId: itemId,
            retryCount: retryCount,
            error: error
        )
    }

    func debugRegisterCoverArtTask(_ task: Task<Void, Never>, for bookId: UUID) {
        uiCoverArtCoordinator.debugRegisterTask(task, for: bookId)
    }

    func debugResetCoverArtTasks() {
        uiCoverArtCoordinator.debugResetState()
    }
#endif
}
