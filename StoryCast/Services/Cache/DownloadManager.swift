import Foundation
import Combine
import os
import SwiftData

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDelegate {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [UUID: DownloadState] = [:]

    struct DownloadState {
        let bookId: UUID
        var progress: Double
        var status: Status
        enum Status { case queued, downloading, paused, completed, failed(Error) }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "StoryCast.DownloadManager")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var taskMap: [URLSessionDownloadTask: UUID] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var resumedContinuations: Set<UUID> = []
    private var modelContainers: [UUID: ModelContainer] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private override init() { super.init() }

    func storeBackgroundCompletionHandler(identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completionHandler
    }

    func downloadBook(_ book: Book, server: ABSServer, container: ModelContainer) async throws {
        guard book.isRemote, let itemId = book.remoteItemId else { return }
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else { throw APIError.tokenMissing }
        modelContainers[book.id] = container

        let item = try await AudiobookshelfAPI.shared.fetchLibraryItem(baseURL: server.normalizedURL, token: token, itemId: itemId)
        guard let firstTrack = item.media.tracks?.first, let contentUrl = firstTrack.contentUrl else { throw APIError.invalidResponse }

        let stream: AuthenticatedStream
        do { stream = try await AudiobookshelfAPI.shared.authenticatedStream(baseURL: server.normalizedURL, token: token, contentUrl: contentUrl) }
        catch { AppLogger.sync.error("Failed to create authenticated stream for download: \(error.localizedDescription, privacy: .private)"); throw error }

        let bookId = book.id
        let fileExtension = DownloadManager.extractFileExtension(from: contentUrl)
        downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .queued)
        resumedContinuations.remove(bookId)
        cancelTimeoutTask(for: bookId)

        try await withCheckedThrowingContinuation { continuation in
            continuations[bookId] = continuation
            let task = session.downloadTask(with: stream.makeRequest())
            taskMap[task] = bookId
            task.taskDescription = fileExtension
            downloads[bookId]?.status = .downloading
            task.resume()
            AppLogger.sync.info("Download started for book \(bookId, privacy: .private)")
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(ImportDefaults.downloadTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if !resumedContinuations.contains(bookId), timeoutTasks[bookId] != nil {
                    resumeContinuation(for: bookId, result: .failure(APIError.serverUnreachable))
                    cancelTimeoutTask(for: bookId)
                }
            }
            registerTimeoutTask(timeoutTask, for: bookId)
        }
        cancelTimeoutTask(for: bookId)
    }

    func cancelDownload(bookId: UUID) {
        cancelTimeoutTask(for: bookId)
        if let task = taskMap.first(where: { $0.value == bookId })?.key { taskMap.removeValue(forKey: task); task.cancel() }
        downloads.removeValue(forKey: bookId)
        modelContainers.removeValue(forKey: bookId)
        resumeContinuation(for: bookId, result: .failure(CancellationError()))
    }

    func cancelDownloads(for bookIds: Set<UUID>) { for bookId in bookIds { cancelDownload(bookId: bookId) } }
    func progress(for bookId: UUID) -> Double? { downloads[bookId]?.progress }

    private func resumeContinuation(for bookId: UUID, result: Result<Void, Error>) {
        guard resumedContinuations.insert(bookId).inserted, let continuation = continuations.removeValue(forKey: bookId) else { return }
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func registerTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) { cancelTimeoutTask(for: bookId); timeoutTasks[bookId] = task }
    private func cancelTimeoutTask(for bookId: UUID) { timeoutTasks.removeValue(forKey: bookId)?.cancel() }

    private func finishDownload(bookId: UUID, localURL: URL, fileExtension: String, container: ModelContainer) async {
        defer { cancelTimeoutTask(for: bookId); modelContainers.removeValue(forKey: bookId) }
        let fileName = "\(bookId.uuidString)_remote.\(fileExtension)"
        let fileManager = FileManager.default
        let context = ModelContext(container)
        let destURL = StorageManager.shared.remoteAudioCacheURL(for: fileName)
        let stagedURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        let backupURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)

        do {
            try await StorageManager.shared.setupRemoteAudioCacheDirectory()
            let existingDestinationURL: URL? = fileManager.fileExists(atPath: destURL.path) ? destURL : nil
            try fileManager.moveItem(at: localURL, to: stagedURL)
            if let existingDestinationURL { try fileManager.moveItem(at: existingDestinationURL, to: backupURL) }

            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookId })
            descriptor.fetchLimit = 1
            guard let book = try context.fetch(descriptor).first else { throw APIError.invalidResponse }

            let previousIsDownloaded = book.isDownloaded
            let previousLocalCachePath = book.localCachePath

            do {
                try fileManager.moveItem(at: stagedURL, to: destURL)
                book.isDownloaded = true
                book.localCachePath = fileName
                guard book.isValid else { throw APIError.invalidResponse }
                try context.save()
                safeRemoveFile(at: backupURL, label: "backup file after successful download")
                downloads[bookId]?.status = .completed
                downloads[bookId]?.progress = 1.0
                AppLogger.sync.info("Download completed for book \(bookId, privacy: .private)")
            } catch {
                rollbackDownload(book: book, previousIsDownloaded: previousIsDownloaded, previousLocalCachePath: previousLocalCachePath, context: context)
                safeMoveFile(from: backupURL, to: destURL, label: "backup audiobook file during error recovery")
                safeRemoveFile(at: stagedURL, label: "staged file during error recovery")
                downloads[bookId]?.status = .failed(error)
                AppLogger.sync.error("Download finish failed: \(error.localizedDescription, privacy: .private)")
                resumeContinuation(for: bookId, result: .failure(error))
                return
            }
        } catch {
            safeMoveFile(from: backupURL, to: destURL, label: "backup audiobook file in outer error recovery")
            safeRemoveFile(at: stagedURL, label: "staged file in outer error recovery")
            safeRemoveFile(at: localURL, label: "downloaded temp file in outer error recovery")
            downloads[bookId]?.status = .failed(error)
            AppLogger.sync.error("Download finish failed: \(error.localizedDescription, privacy: .private)")
            resumeContinuation(for: bookId, result: .failure(error))
            return
        }
        resumeContinuation(for: bookId, result: .success(()))
    }

    private func rollbackDownload(book: Book, previousIsDownloaded: Bool, previousLocalCachePath: String?, context: ModelContext) {
        safeRemoveFile(at: StorageManager.shared.remoteAudioCacheURL(for: book.localCachePath ?? ""), label: "corrupt destination file during error recovery")
        book.isDownloaded = previousIsDownloaded
        book.localCachePath = previousLocalCachePath
        context.rollback()
    }

    private func safeRemoveFile(at url: URL, label: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { AppLogger.sync.warning("Failed to remove \(label): \(error.localizedDescription, privacy: .private)") }
    }

    private func safeMoveFile(from source: URL, to destination: URL, label: String) {
        guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) else { return }
        do { try FileManager.default.moveItem(at: source, to: destination) }
        catch { AppLogger.sync.error("CRITICAL: Failed to restore \(label). Path: \(destination.path, privacy: .private), error: \(error.localizedDescription, privacy: .private)") }
    }

    nonisolated static func extractFileExtension(from contentUrl: String) -> String {
        if let url = URL(string: contentUrl) {
            let ext = url.deletingQuery().pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        let known = ["m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus"]
        for candidate in known where contentUrl.lowercased().contains(".\(candidate)") { return candidate }
        return "m4b"
    }
}

private extension URL {
    nonisolated func deletingQuery() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.query = nil
        return components.url ?? self
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            let error = APIError.httpError(statusCode: response.statusCode)
            Task { @MainActor [weak self] in self?.handleDownloadError(downloadTask: downloadTask, error: error) }
            return
        }

        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.copyItem(at: location, to: tempDest) }
        catch { Task { @MainActor [weak self] in self?.handleDownloadError(downloadTask: downloadTask, error: error) }; return }

        let fileExtension = downloadTask.taskDescription?.isEmpty == false ? downloadTask.taskDescription! : DownloadManager.extractFileExtension(from: downloadTask.originalRequest?.url?.absoluteString ?? "")
        Task { @MainActor [weak self] in
            guard let self, let bookId = taskMap[downloadTask], let container = modelContainers[bookId] else {
                self?.handleDownloadError(downloadTask: downloadTask, error: APIError.invalidResponse)
                return
            }
            taskMap.removeValue(forKey: downloadTask)
            await finishDownload(bookId: bookId, localURL: tempDest, fileExtension: fileExtension, container: container)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self, let bookId = taskMap[downloadTask] else { return }
            downloads[bookId]?.progress = progress
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let downloadTask = task as? URLSessionDownloadTask else { return }
        Task { @MainActor [weak self] in
            guard let self, let bookId = taskMap[downloadTask], !resumedContinuations.contains(bookId) else { return }
            handleDownloadError(downloadTask: downloadTask, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (identifier, completionHandler) in self.backgroundCompletionHandlers {
                AppLogger.sync.info("All background tasks finished for session \(identifier, privacy: .private) — calling system completion handler")
                self.backgroundCompletionHandlers.removeValue(forKey: identifier)
                completionHandler()
            }
        }
    }

    private func handleDownloadError(downloadTask: URLSessionDownloadTask, error: Error) {
        guard let bookId = taskMap.removeValue(forKey: downloadTask) else { return }
        cancelTimeoutTask(for: bookId)
        modelContainers.removeValue(forKey: bookId)
        downloads[bookId]?.status = .failed(error)
        resumeContinuation(for: bookId, result: .failure(error))
        AppLogger.sync.error("Download failed: \(error.localizedDescription, privacy: .private)")
    }
}

#if DEBUG
extension DownloadManager {
    var debugTimeoutTaskCount: Int { timeoutTasks.count }
    var debugDownloadCount: Int { downloads.count }
    var debugBackgroundCompletionHandlerCount: Int { backgroundCompletionHandlers.count }
    func debugFinishDownload(bookId: UUID, localURL: URL, fileExtension: String, container: ModelContainer) async {
        await finishDownload(bookId: bookId, localURL: localURL, fileExtension: fileExtension, container: container)
    }

    func debugRegisterTrackedDownload(bookId: UUID, timeoutTask: Task<Void, Never>? = nil) {
        downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .downloading)
        if let timeoutTask { registerTimeoutTask(timeoutTask, for: bookId) }
    }
    func debugResetState() {
        for timeoutTask in timeoutTasks.values { timeoutTask.cancel() }
        timeoutTasks.removeAll(); downloads.removeAll(); continuations.removeAll(); resumedContinuations.removeAll(); taskMap.removeAll(); modelContainers.removeAll(); backgroundCompletionHandlers.removeAll()
    }
    func debugRegisterTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) { registerTimeoutTask(task, for: bookId) }
    func debugCancelTimeoutTask(for bookId: UUID) { cancelTimeoutTask(for: bookId) }
}
#endif
