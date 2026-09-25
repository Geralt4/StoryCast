import SwiftData
import Foundation
import os

/// Handles remote book download and cache management for the library view.
///
/// `LibraryRemoteBookHandler` provides:
/// - Remote book download coordination via `DownloadManager`
/// - Cache cleanup for downloaded books
/// - Error handling and user feedback
/// - Integration with SwiftData for book record updates
///
/// ## Remote Book Lifecycle
///
/// 1. **Discovery**: Remote books appear in the library via `RemoteLibraryService` sync
/// 2. **Download**: User initiates download → `DownloadManager` fetches audio file
/// 3. **Caching**: File stored in app sandbox, book marked as `isDownloaded`
/// 4. **Playback**: Downloaded books play locally; undownloaded books stream
/// 5. **Cleanup**: User can remove download to free space while keeping remote reference
///
/// ## Thread Safety
///
/// All operations are performed on the main actor to ensure thread-safe access to
/// SwiftData records. File operations use `Task.detached` with appropriate priorities.
///
/// ## Error Handling
///
/// Download failures are presented to the user via error alerts coordinated by
/// the parent view model. Cache cleanup errors are logged but don't block UI.
///
/// ## Usage
///
/// ```swift
/// let handler = LibraryRemoteBookHandler(modelContext: context)
/// handler.downloadBook(remoteBook)
/// handler.removeDownloadedBook(downloadedBook)
/// ```
@MainActor
final class LibraryRemoteBookHandler {
    // MARK: - Dependencies
    
    /// The SwiftData model context for updating book records.
    private unowned let modelContext: ModelContext
    
    // MARK: - Initialization
    
    /// Creates a remote book handler.
    ///
    /// - Parameter modelContext: SwiftData model context for database operations.
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Public Interface
    
    /// Downloads a remote book to local cache.
    ///
    /// - Parameter book: The remote book to download.
    ///
    /// ## Flow
    /// 1. Validates the book is remote and has a server ID
    /// 2. Fetches the corresponding `ABSServer` record
    /// 3. Delegates to `DownloadManager.shared.downloadBook`
    /// 4. Presents errors via the parent view model
    func downloadBook(_ book: Book) {
        guard book.isRemote, let serverId = book.serverId else { return }
        
        Task {
            let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
            do {
                guard let server = try modelContext.fetch(descriptor).first else {
                    AppLogger.network.error("Server not found for download: \(serverId.uuidString, privacy: .private(mask: .hash))")
                    return
                }
                try await DownloadManager.shared.downloadBook(
                    book,
                    server: server,
                    container: modelContext.container
                )
            } catch {
                AppLogger.network.error(
                    "Failed to download book '\(book.title, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
    
    /// Removes the downloaded cache for a remote book.
    ///
    /// - Parameter book: The remote book to remove from cache.
    ///
    /// ## Flow
    /// 1. Validates the book is remote, downloaded, and has a cache path
    /// 2. Deletes the cached audio file from the app sandbox
    /// 3. Updates the book record (`isDownloaded = false`, `localCachePath = nil`)
    /// 4. Silently logs file deletion errors (user can retry manually)
    func removeDownloadedBook(_ book: Book) {
        guard book.isRemote, book.isDownloaded, let cachePath = book.localCachePath else { return }
        
        // Stop playing the downloaded files before they are deleted; otherwise
        // the next queued file would fail mid-book.
        let player = AudioPlayerService.shared
        if player.currentBookID == book.id, player.currentSource?.isLocal == true {
            player.unload()
        }

        Task {
            let previousIsDownloaded = book.isDownloaded
            let previousLocalCachePath = book.localCachePath

            do {
                _ = try StorageCleanupCoordinator.stage(
                    location: .remoteAudioCache,
                    relativePath: cachePath,
                    in: modelContext
                )
                book.isDownloaded = false
                book.localCachePath = nil
                try modelContext.save()
                StorageCleanupCoordinator.drainPendingCleanup(in: modelContext)
            } catch {
                modelContext.rollback()
                book.isDownloaded = previousIsDownloaded
                book.localCachePath = previousLocalCachePath
                AppLogger.storage.error(
                    "Failed to update book record after cache removal: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}
