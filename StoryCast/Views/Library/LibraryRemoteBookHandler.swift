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
        
        Task {
            let previousIsDownloaded = book.isDownloaded
            let previousLocalCachePath = book.localCachePath
            book.isDownloaded = false
            book.localCachePath = nil
            
            do {
                try modelContext.save()
                await StorageManager.shared.deleteRemoteAudioCache(fileName: cachePath)
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
    
    /// Downloads multiple remote books sequentially.
    ///
    /// - Parameter books: Array of remote books to download.
    /// - Parameter completion: Callback with count of successful downloads.
    ///
    /// ## Performance Considerations
    /// Downloads are processed sequentially to avoid overwhelming the network
    /// and to provide predictable progress. Consider background queue for large batches.
    func downloadBooks(_ books: [Book], completion: ((Int) -> Void)? = nil) {
        Task {
            var successfulCount = 0
            
            for book in books {
                guard book.isRemote, let serverId = book.serverId else { continue }
                
                let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                do {
                    guard let server = try modelContext.fetch(descriptor).first else {
                        AppLogger.network.warning("Server not found for batch download: \(serverId.uuidString, privacy: .private(mask: .hash))")
                        continue
                    }
                    try await DownloadManager.shared.downloadBook(
                        book,
                        server: server,
                        container: modelContext.container
                    )
                    successfulCount += 1
                } catch {
                    AppLogger.network.error(
                        "Failed to download book '\(book.title, privacy: .private)' in batch: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            
            completion?(successfulCount)
        }
    }
    
    /// Removes downloaded cache for multiple remote books.
    ///
    /// - Parameter books: Array of remote books to remove from cache.
    /// - Returns: Count of books successfully removed from cache.
    ///
    /// ## File Operations
    /// File deletions are performed in a detached task to avoid blocking the UI.
    /// Book record updates are batched into a single save operation for efficiency.
    func removeDownloadedBooks(_ books: [Book]) async -> Int {
        let booksToRemove = books.filter { $0.isRemote && $0.isDownloaded && $0.localCachePath != nil }
        guard !booksToRemove.isEmpty else { return 0 }
        
        let originalStates = booksToRemove.map { book in
            (book: book, isDownloaded: book.isDownloaded, localCachePath: book.localCachePath)
        }

        for book in booksToRemove {
            book.isDownloaded = false
            book.localCachePath = nil
        }
        
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            for state in originalStates {
                state.book.isDownloaded = state.isDownloaded
                state.book.localCachePath = state.localCachePath
            }
            AppLogger.storage.error(
                "Failed to save batch cache removal: \(error.localizedDescription, privacy: .private)"
            )
            return 0
        }

        await withTaskGroup(of: Void.self) { group in
            for state in originalStates {
                guard let cachePath = state.localCachePath else { continue }

                group.addTask {
                    await StorageManager.shared.deleteRemoteAudioCache(fileName: cachePath)
                }
            }
        }
        
        return originalStates.count
    }
    
    /// Checks if a remote book is fully downloaded and the cache is valid.
    ///
    /// - Parameter book: The remote book to check.
    /// - Returns: `true` if the book is marked as downloaded and the cache file exists.
    func isBookDownloadValid(_ book: Book) -> Bool {
        guard book.isRemote, book.isDownloaded, let cachePath = book.localCachePath else {
            return false
        }
        
        let fileURL = StorageManager.shared.resolvedRemoteAudioCacheURL(for: cachePath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// Returns the total size of cached files for a list of remote books.
    ///
    /// - Parameter books: Array of remote books to calculate cache size for.
    /// - Returns: Total size in bytes, or `nil` if unable to calculate.
    func cachedSize(for books: [Book]) async -> Int64? {
        let booksWithCache = books.filter { $0.isRemote && $0.isDownloaded && $0.localCachePath != nil }
        
        return await withTaskGroup(of: Int64?.self) { group -> Int64 in
            for book in booksWithCache {
                guard let cachePath = book.localCachePath else { continue }
                let bookTitle = book.title
                
                group.addTask {
                    let fileURL = StorageManager.shared.resolvedRemoteAudioCacheURL(for: cachePath)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
                    
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                        if let size = attributes[.size] as? NSNumber {
                            return size.int64Value
                        }
                    } catch {
                        AppLogger.storage.debug(
                            "Failed to get file size for '\(bookTitle, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                        )
                    }
                    
                    return 0
                }
            }
            
            var total: Int64 = 0
            for await size in group {
                if let size = size {
                    total += size
                }
            }
            
            return total
        }
    }
}
