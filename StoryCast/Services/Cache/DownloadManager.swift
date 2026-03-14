import Foundation
import Combine
import os
import SwiftData

/// Manages background downloads of remote Audiobookshelf books for offline playback.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    // MARK: - Published State

    @Published private(set) var downloads: [UUID: DownloadState] = [:]

    struct DownloadState {
        let bookId: UUID
        var progress: Double       // 0.0 – 1.0
        var status: Status

        enum Status {
            case queued, downloading, paused, completed, failed(Error)
        }
    }

    // MARK: - Private

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "StoryCast.DownloadManager")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var taskMap: [URLSessionDownloadTask: UUID] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Tracks continuations that have already been resumed to prevent double-resume crashes.
    private var resumedContinuations: Set<UUID> = []
    /// Retained for use inside the nonisolated URLSession delegate callbacks.
    private var modelContainer: ModelContainer?
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Downloads the audio file for a remote book and marks it as available offline.
    func downloadBook(_ book: Book, server: ABSServer, container: ModelContainer) async throws {
        guard book.isRemote, let itemId = book.remoteItemId else { return }
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }

        // Retain the container so the nonisolated delegate can hop back onto MainActor with it.
        modelContainer = container

        // Fetch full item detail to get the first audio track URL and size info.
        let item = try await AudiobookshelfAPI.shared.fetchLibraryItem(
            baseURL: server.normalizedURL,
            token: token,
            itemId: itemId
        )

        guard let firstTrack = item.media.tracks?.first,
              let contentUrl = firstTrack.contentUrl else {
            throw APIError.invalidResponse
        }

        let stream: AuthenticatedStream
        do {
            stream = try await AudiobookshelfAPI.shared.authenticatedStream(
                baseURL: server.normalizedURL,
                token: token,
                contentUrl: contentUrl
            )
        } catch {
            AppLogger.sync.error("Failed to create authenticated stream for download: \(error.localizedDescription, privacy: .private)")
            throw error
        }

        let bookId = book.id
        // Extract the file extension from the content URL so the saved file stays playable.
        let fileExtension = DownloadManager.extractFileExtension(from: contentUrl)
        downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .queued)
        resumedContinuations.remove(bookId)
        cancelTimeoutTask(for: bookId)

        try await withCheckedThrowingContinuation { continuation in
            continuations[bookId] = continuation
            let task = session.downloadTask(with: stream.makeRequest())
            taskMap[task] = bookId
            // Store the resolved extension on the task description so the delegate can retrieve it.
            task.taskDescription = fileExtension
            downloads[bookId]?.status = .downloading
            task.resume()
            AppLogger.sync.info("Download started for book \(bookId, privacy: .private)")
            
            // Ensure continuation is resumed if task is cancelled externally
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minute timeout
                guard !Task.isCancelled else { return }
                if !resumedContinuations.contains(bookId), timeoutTasks[bookId] != nil {
                    resumeContinuation(for: bookId, result: .failure(APIError.serverUnreachable))
                    cancelTimeoutTask(for: bookId)
                }
            }
            registerTimeoutTask(timeoutTask, for: bookId)
        }
        
        // Cancel timeout task when download completes
        cancelTimeoutTask(for: bookId)
    }

    /// Cancels an in-progress download.
    func cancelDownload(bookId: UUID) {
        cancelTimeoutTask(for: bookId)
        if let task = taskMap.first(where: { $0.value == bookId })?.key {
            taskMap.removeValue(forKey: task)
            task.cancel()
        }
        downloads.removeValue(forKey: bookId)
        resumeContinuation(for: bookId, result: .failure(CancellationError()))
    }

    /// Cancels all tracked downloads for the supplied book IDs.
    func cancelDownloads(for bookIds: Set<UUID>) {
        for bookId in bookIds {
            cancelDownload(bookId: bookId)
        }
    }

    /// Returns the download progress (0–1) for a book, or nil if not downloading.
    func progress(for bookId: UUID) -> Double? {
        downloads[bookId]?.progress
    }

    // MARK: - Safe Continuation Resume

    /// Resumes the stored continuation for `bookId` at most once.
    /// Subsequent calls for the same `bookId` are silently ignored,
    /// preventing "already resumed" crashes from the delegate / error path racing.
    private func resumeContinuation(for bookId: UUID, result: Result<Void, Error>) {
        // insert(_:) returns (inserted: true) only the first time — guarantees single resume.
        guard resumedContinuations.insert(bookId).inserted,
              let continuation = continuations.removeValue(forKey: bookId) else {
            return
        }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func registerTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) {
        cancelTimeoutTask(for: bookId)
        timeoutTasks[bookId] = task
    }

    private func cancelTimeoutTask(for bookId: UUID) {
        if let timeoutTask = timeoutTasks.removeValue(forKey: bookId) {
            timeoutTask.cancel()
        }
    }

    // MARK: - Finish Download

    private func finishDownload(bookId: UUID, localURL: URL, fileExtension: String, container: ModelContainer) async {
        defer { cancelTimeoutTask(for: bookId) }
        let fileName = "\(bookId.uuidString)_remote.\(fileExtension)"
        let fileManager = FileManager.default
        let context = ModelContext(container)
        let destURL = StorageManager.shared.remoteAudioCacheURL(for: fileName)
        let stagedURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        let backupURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try await StorageManager.shared.setupRemoteAudioCacheDirectory()
            let existingDestinationURL: URL? = fileManager.fileExists(atPath: destURL.path) ? destURL : nil

            try fileManager.moveItem(at: localURL, to: stagedURL)

            if let existingDestinationURL {
                try fileManager.moveItem(at: existingDestinationURL, to: backupURL)
            }

            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookId })
            descriptor.fetchLimit = 1
            guard let book = try context.fetch(descriptor).first else {
                throw APIError.invalidResponse
            }

            let previousIsDownloaded = book.isDownloaded
            let previousLocalCachePath = book.localCachePath

            do {
                try fileManager.moveItem(at: stagedURL, to: destURL)

                book.isDownloaded = true
                book.localCachePath = fileName
                guard book.isValid else {
                    throw APIError.invalidResponse
                }
                try context.save()

                if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        AppLogger.sync.warning("Failed to remove backup file after successful download: \(error.localizedDescription, privacy: .private)")
                    }
                }
            } catch {
                if fileManager.fileExists(atPath: destURL.path) {
                    do {
                        try fileManager.removeItem(at: destURL)
                    } catch {
                        AppLogger.sync.warning("Failed to remove corrupt destination file during error recovery: \(error.localizedDescription, privacy: .private)")
                    }
                }
                if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        try fileManager.moveItem(at: backupURL, to: destURL)
                    } catch {
                        AppLogger.sync.error("CRITICAL: Failed to restore backup audiobook file during error recovery. User's cached audiobook may be lost. Path: \(destURL.path, privacy: .private), error: \(error.localizedDescription, privacy: .private)")
                    }
                }
                if fileManager.fileExists(atPath: stagedURL.path) {
                    do {
                        try fileManager.removeItem(at: stagedURL)
                    } catch {
                        AppLogger.sync.warning("Failed to remove staged file during error recovery: \(error.localizedDescription, privacy: .private)")
                    }
                }

                book.isDownloaded = previousIsDownloaded
                book.localCachePath = previousLocalCachePath
                context.rollback()
                throw error
            }

            downloads[bookId]?.status = .completed
            downloads[bookId]?.progress = 1.0
            AppLogger.sync.info("Download completed for book \(bookId, privacy: .private)")
        } catch {
            if fileManager.fileExists(atPath: backupURL.path), !fileManager.fileExists(atPath: destURL.path) {
                do {
                    try fileManager.moveItem(at: backupURL, to: destURL)
                } catch {
                    AppLogger.sync.error("CRITICAL: Failed to restore backup audiobook file in outer error recovery. User's cached audiobook may be lost. Path: \(destURL.path, privacy: .private), error: \(error.localizedDescription, privacy: .private)")
                }
            }
            if fileManager.fileExists(atPath: stagedURL.path) {
                do {
                    try fileManager.removeItem(at: stagedURL)
                } catch {
                    AppLogger.sync.warning("Failed to remove staged file in outer error recovery: \(error.localizedDescription, privacy: .private)")
                }
            }
            if fileManager.fileExists(atPath: localURL.path) {
                do {
                    try fileManager.removeItem(at: localURL)
                } catch {
                    AppLogger.sync.warning("Failed to remove downloaded temp file in outer error recovery: \(error.localizedDescription, privacy: .private)")
                }
            }
            downloads[bookId]?.status = .failed(error)
            AppLogger.sync.error("Download finish failed: \(error.localizedDescription, privacy: .private)")
            resumeContinuation(for: bookId, result: .failure(error))
            return
        }

        resumeContinuation(for: bookId, result: .success(()))
    }

    // MARK: - File Extension Extraction

    /// Extracts the audio file extension from a content URL path.
    /// Falls back to "m4b" (the most common audiobook format) if none can be determined.
    /// Marked `nonisolated` so it can be called safely from URLSession delegate callbacks.
    nonisolated static func extractFileExtension(from contentUrl: String) -> String {
        // Strip query string before asking pathExtension, so "track.mp3?token=xxx" works.
        if let url = URL(string: contentUrl) {
            let ext = url.deletingQuery().pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }
        // Last-ditch: scan the raw string for a known audio extension before a "?" or end.
        let known = ["m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus"]
        for candidate in known where contentUrl.lowercased().contains(".\(candidate)") {
            return candidate
        }
        return "m4b"
    }
}

// MARK: - URL Helper

private extension URL {
    /// Returns a copy of the URL with the query string removed.
    nonisolated func deletingQuery() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        return components.url ?? self
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            let error = APIError.httpError(statusCode: response.statusCode)
            Task { @MainActor [weak self] in
                guard let self,
                      let bookId = taskMap[downloadTask] else { return }
                taskMap.removeValue(forKey: downloadTask)
                cancelTimeoutTask(for: bookId)
                downloads[bookId]?.status = .failed(error)
                resumeContinuation(for: bookId, result: .failure(error))
                AppLogger.sync.error("Download failed with HTTP \(response.statusCode)")
            }
            return
        }
        
        // Copy the file to a stable temp location before the system deletes it.
        let tempDest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: tempDest)
        } catch {
            let error = error
            Task { @MainActor [weak self] in
                guard let self,
                      let bookId = taskMap[downloadTask] else { return }
                taskMap.removeValue(forKey: downloadTask)
                cancelTimeoutTask(for: bookId)
                downloads[bookId]?.status = .failed(error)
                resumeContinuation(for: bookId, result: .failure(error))
                AppLogger.sync.error("Failed to copy downloaded file: \(error.localizedDescription, privacy: .private)")
            }
            return
        }
        // Recover the file extension stored on the task, falling back to URL extraction.
        let fileExtension: String
        if let stored = downloadTask.taskDescription, !stored.isEmpty {
            fileExtension = stored
        } else {
            let rawURL = downloadTask.originalRequest?.url?.absoluteString ?? ""
            fileExtension = DownloadManager.extractFileExtension(from: rawURL)
        }

        Task { @MainActor [weak self] in
            guard let self,
                  let bookId = taskMap[downloadTask] else { return }
            taskMap.removeValue(forKey: downloadTask)
            guard let container = modelContainer else {
                let error = APIError.invalidResponse
                cancelTimeoutTask(for: bookId)
                downloads[bookId]?.status = .failed(error)
                resumeContinuation(for: bookId, result: .failure(error))
                AppLogger.sync.error("Download failed: missing model container")
                return
            }
            await finishDownload(bookId: bookId, localURL: tempDest, fileExtension: fileExtension, container: container)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self, let bookId = taskMap[downloadTask] else { return }
            downloads[bookId]?.progress = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let downloadTask = task as? URLSessionDownloadTask,
                  let bookId = taskMap[downloadTask],
                  !resumedContinuations.contains(bookId) else { return }
            taskMap.removeValue(forKey: downloadTask)
            cancelTimeoutTask(for: bookId)
            downloads[bookId]?.status = .failed(error)
            resumeContinuation(for: bookId, result: .failure(error))
            AppLogger.sync.error("Download failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

#if DEBUG
extension DownloadManager {
    var debugTimeoutTaskCount: Int { timeoutTasks.count }

    var debugDownloadCount: Int { downloads.count }

    func debugFinishDownload(bookId: UUID, localURL: URL, fileExtension: String, container: ModelContainer) async {
        await finishDownload(bookId: bookId, localURL: localURL, fileExtension: fileExtension, container: container)
    }

    func debugRegisterTrackedDownload(bookId: UUID, timeoutTask: Task<Void, Never>? = nil) {
        downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .downloading)
        if let timeoutTask {
            registerTimeoutTask(timeoutTask, for: bookId)
        }
    }

    func debugResetState() {
        for timeoutTask in timeoutTasks.values {
            timeoutTask.cancel()
        }
        timeoutTasks.removeAll()
        downloads.removeAll()
        continuations.removeAll()
        resumedContinuations.removeAll()
        taskMap.removeAll()
    }

    func debugRegisterTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) {
        registerTimeoutTask(task, for: bookId)
    }

    func debugCancelTimeoutTask(for bookId: UUID) {
        cancelTimeoutTask(for: bookId)
    }
}
#endif
