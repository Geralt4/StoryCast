import Foundation
import Combine
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum DownloadManagerError: LocalizedError {
    case downloadInProgress

    var errorDescription: String? {
        "This book is already downloading."
    }
}

/// Downloads every file of an Audiobookshelf book with a background
/// URLSession and stores it as a folder download.
///
/// Files arrive in `DownloadStaging/<bookId>/` and the book is finalized (the
/// folder moved into the remote cache and the book marked downloaded) once all
/// of them are present. Each task carries a `DownloadTaskTag`, so downloads
/// continue and finish even after iOS terminates and relaunches the app:
/// `activate()` reattaches running tasks and `reconcile` finishes or reports
/// books whose files arrived while the app wasn't running.
@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDelegate {
    static let shared = DownloadManager()
    static let sessionIdentifier = "StoryCast.DownloadManager"

    @Published private(set) var downloads: [UUID: DownloadState] = [:]
    /// Failed downloads the user hasn't been told about yet, oldest first.
    @Published private(set) var failureNotices: [DownloadFailureNotice] = []

    nonisolated struct DownloadState {
        let bookId: UUID
        var progress: Double
        var status: Status
        var completedTracks: Int = 0
        var totalTracks: Int = 0
        enum Status { case queued, downloading, paused, completed, failed(Error) }

        var isActive: Bool {
            switch status {
            case .queued, .downloading: return true
            case .paused, .completed, .failed: return false
            }
        }

        var failure: DownloadFailure? {
            if case .failed(let error) = status { return DownloadFailure.classify(error) }
            return nil
        }
    }

    /// Why the app cancelled a task, recorded before calling `cancel()` so the
    /// resulting error can be told apart from the system cancelling it.
    enum CancelReason: Sendable {
        case user
        case sibling
        case stalled
    }

    private var session: URLSession?
    private var isActivated = false
    private var configuredContainer: ModelContainer?
    private var modelContainers: [UUID: ModelContainer] = [:]
    private var activeTasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
    private var manifests: [UUID: RemoteDownloadManifest] = [:]
    private var completedIndices: [UUID: Set<Int>] = [:]
    private var inFlightBytes: [UUID: [Int: Int64]] = [:]
    private var inFlightFractions: [UUID: [Int: Double]] = [:]
    private var lastProgressPublish: [UUID: (date: Date, progress: Double)] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var resumedContinuations: Set<UUID> = []
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var interruptionChecks: [UUID: Task<Void, Never>] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private var finalizing: Set<UUID> = []
    private var pendingFinalizations: Set<UUID> = []
    private var apiOverride: AudiobookshelfAPI?
    private var stallTimeoutOverride: TimeInterval?
    private var interruptionGracePeriod: TimeInterval = 10
    private var api: AudiobookshelfAPI { apiOverride ?? .shared }
    nonisolated private let cancelReasons = OSAllocatedUnfairLock<[Int: CancelReason]>(initialState: [:])
    nonisolated private let progressThrottle = OSAllocatedUnfairLock<[Int: TimeInterval]>(initialState: [:])

    private override init() { super.init() }

    /// Unit tests run inside the app, which must not adopt or finalize real
    /// downloads there. The opt-in integration tests set STORYCAST_ABS_IT=1.
    nonisolated static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil && environment["STORYCAST_ABS_IT"] != "1"
    }

    // MARK: - Launch

    /// Hands over the app's model container so downloads that finish without a
    /// waiting caller (for example after a relaunch) can be finalized.
    func configure(container: ModelContainer) {
        configuredContainer = container
        let pending = pendingFinalizations
        pendingFinalizations.removeAll()
        for bookId in pending {
            finalize(bookId: bookId, notify: true)
        }
    }

    /// Recreates the background session and reattaches downloads that kept
    /// running while the app was not. Safe to call more than once.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        let session = activeSession()
        guard !Self.isRunningUnitTests else { return }
        Task { @MainActor [weak self] in
            let tasks = await session.allTasks
            self?.reconcile(tasks: tasks)
        }
    }

    func storeBackgroundCompletionHandler(identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completionHandler
    }

    private func activeSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        return session
    }

    // MARK: - Starting

    func downloadBook(_ book: Book, server: ABSServer, container: ModelContainer) async throws {
        guard book.isRemote, let itemId = book.remoteItemId else { return }

        let bookId = book.id
        let title = book.title
        let serverID = server.id
        let baseURL = server.normalizedURL
        // Reject a second concurrent download for the same book: two attempts
        // would race writing the same files.
        try Self.ensureNotAlreadyDownloading(bookId: bookId, downloads: downloads, continuations: continuations)
        guard activeTasks[bookId]?.isEmpty ?? true else { throw DownloadManagerError.downloadInProgress }

        guard let token = await AudiobookshelfAuth.shared.token(for: baseURL) else {
            postNotice(bookId: bookId, title: title, failure: .unauthorized)
            throw APIError.tokenMissing
        }

        let manifest: RemoteDownloadManifest
        let requests: [URLRequest]
        do {
            try await checkDownloadPermission(baseURL: baseURL, token: token)
            let item = try await api.fetchLibraryItem(baseURL: baseURL, token: token, itemId: itemId)
            manifest = try RemoteDownloadPlanner.makeManifest(
                item: item,
                bookID: bookId,
                serverID: serverID,
                title: title,
                attempt: UUID(),
                now: Date()
            )
            // Every file URL goes through the same validator as streaming.
            var validated: [URLRequest] = []
            for track in PlaybackTimeline.playbackOrder(item.media.tracks ?? [], startOffset: \.startOffset) {
                guard let contentUrl = track.contentUrl ?? track.ino.map({ "/api/items/\(itemId)/file/\($0)" }) else {
                    throw DownloadFailure.invalidResponse
                }
                let stream = try await api.authenticatedStream(baseURL: baseURL, token: token, contentUrl: contentUrl)
                validated.append(stream.makeRequest())
            }
            requests = validated

            // Another call may have started this book while we were fetching.
            try assertNotAlreadyDownloading(bookId: bookId)
            try DownloadStaging.prepare(manifest)
            try? StorageManager.applyDownloadFolderAttributes(to: DownloadStaging.folder(for: bookId))
        } catch let error as DownloadManagerError {
            throw error
        } catch {
            postNotice(bookId: bookId, title: title, failure: DownloadFailure.classify(error))
            throw error
        }

        try await start(manifest: manifest, requests: requests, container: container)
    }

    /// Fails early when the server says this account may not download.
    private func checkDownloadPermission(baseURL: String, token: String) async throws {
        let user: ABSUserResponse
        do {
            user = try await api.authorize(baseURL: baseURL, token: token)
        } catch APIError.unauthorized {
            throw DownloadFailure.unauthorized
        } catch {
            // Older servers or a transient error: let the download itself decide.
            return
        }
        if user.permissions?.download == false {
            throw DownloadFailure.forbidden
        }
    }

    private func start(manifest: RemoteDownloadManifest, requests: [URLRequest], container: ModelContainer) async throws {
        let bookId = manifest.bookId
        let missing = DownloadStaging.missingTrackIndices(for: manifest)
        modelContainers[bookId] = container
        manifests[bookId] = manifest
        completedIndices[bookId] = Set(manifest.tracks.indices).subtracting(missing)
        inFlightBytes[bookId] = [:]
        inFlightFractions[bookId] = [:]
        resumedContinuations.remove(bookId)
        interruptionChecks.removeValue(forKey: bookId)?.cancel()
        downloads[bookId] = DownloadState(
            bookId: bookId,
            progress: 0,
            status: .queued,
            completedTracks: manifest.tracks.count - missing.count,
            totalTracks: manifest.tracks.count
        )
        publishProgress(for: bookId, force: true)

        guard !missing.isEmpty else {
            // Everything was already staged by an earlier attempt.
            if case .failure(let failure) = finalize(bookId: bookId, notify: true) {
                throw failure
            }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations[bookId] = continuation
            let session = activeSession()
            var tasks: [Int: URLSessionDownloadTask] = [:]
            for index in missing {
                let track = manifest.tracks[index]
                let tag = DownloadTaskTag(bookId: bookId, attempt: manifest.attempt, trackIndex: index, ino: track.ino, ext: track.ext)
                let task: URLSessionDownloadTask
                if let resumeData = DownloadStaging.takeResumeData(bookID: bookId, trackIndex: index) {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: requests[index])
                }
                task.taskDescription = tag.encoded()
                tasks[index] = task
            }
            activeTasks[bookId] = tasks
            downloads[bookId]?.status = .downloading
            tasks.values.forEach { $0.resume() }
            startWatchdog(for: bookId)
            AppLogger.sync.info("Download started for book \(bookId, privacy: .private): \(tasks.count) of \(manifest.tracks.count) file(s)")
        }
    }

    private func assertNotAlreadyDownloading(bookId: UUID) throws {
        try Self.ensureNotAlreadyDownloading(bookId: bookId, downloads: downloads, continuations: continuations)
        guard activeTasks[bookId]?.isEmpty ?? true else { throw DownloadManagerError.downloadInProgress }
    }

    private nonisolated static func ensureNotAlreadyDownloading(
        bookId: UUID,
        downloads: [UUID: DownloadState],
        continuations: [UUID: CheckedContinuation<Void, Error>]
    ) throws {
        if continuations[bookId] != nil {
            throw DownloadManagerError.downloadInProgress
        }
        // A completed or failed entry must not block a future re-download;
        // only queued/downloading states indicate an active transfer.
        if let state = downloads[bookId], state.isActive {
            throw DownloadManagerError.downloadInProgress
        }
    }

    // MARK: - Cancelling

    func cancelDownload(bookId: UUID) {
        fail(bookId: bookId, failure: .cancelled, notify: false)
        downloads.removeValue(forKey: bookId)
        // Tasks not reattached yet (right after a relaunch) are cancelled too.
        guard let session else { return }
        Task { @MainActor [weak self] in
            for task in await session.allTasks where DownloadTaskTag.decode(task.taskDescription)?.bookId == bookId {
                self?.recordCancel(task, reason: .user)
                task.cancel()
            }
        }
    }

    func cancelDownloads(for bookIds: Set<UUID>) { for bookId in bookIds { cancelDownload(bookId: bookId) } }
    func progress(for bookId: UUID) -> Double? { downloads[bookId]?.progress }

    /// Removes a failed book's partially downloaded files.
    func discardPartialDownload(bookId: UUID) {
        guard activeTasks[bookId] == nil else { return }
        DownloadStaging.removeFolder(for: bookId)
        manifests[bookId] = nil
        downloads.removeValue(forKey: bookId)
    }

    func dismissFailureNotice(_ notice: DownloadFailureNotice) {
        failureNotices.removeAll { $0.id == notice.id }
    }

    nonisolated private func recordCancel(_ task: URLSessionTask, reason: CancelReason) {
        cancelReasons.withLock { $0[task.taskIdentifier] = reason }
    }

    // MARK: - Failure

    /// Stops a book's download. Finished files stay staged so a retry only
    /// fetches the missing ones, except after a cancel or a full disk.
    private func fail(bookId: UUID, failure: DownloadFailure, notify: Bool = true, keepResumeData: Bool = false) {
        let tasks = activeTasks.removeValue(forKey: bookId) ?? [:]
        for (index, task) in tasks {
            if keepResumeData {
                recordCancel(task, reason: .stalled)
                task.cancel { data in
                    guard let data else { return }
                    DownloadStaging.saveResumeData(data, bookID: bookId, trackIndex: index)
                }
            } else {
                recordCancel(task, reason: failure == .cancelled ? .user : .sibling)
                task.cancel()
            }
        }
        cancelTimeoutTask(for: bookId)
        interruptionChecks.removeValue(forKey: bookId)?.cancel()
        inFlightBytes[bookId] = nil
        inFlightFractions[bookId] = nil
        lastProgressPublish[bookId] = nil
        modelContainers.removeValue(forKey: bookId)
        let title = manifests[bookId]?.title ?? "This book"
        if failure == .cancelled || failure == .diskFull {
            DownloadStaging.removeFolder(for: bookId)
            manifests[bookId] = nil
            completedIndices[bookId] = nil
        }

        if var state = downloads[bookId] {
            state.status = .failed(failure)
            downloads[bookId] = state
        } else if failure != .cancelled {
            downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .failed(failure))
        }
        resumeContinuation(for: bookId, result: .failure(failure))
        if notify, failure != .cancelled {
            postNotice(bookId: bookId, title: title, failure: failure)
        }
        AppLogger.sync.error("Download failed for book \(bookId, privacy: .private): \(failure.userMessage, privacy: .public)")
    }

    private func postNotice(bookId: UUID, title: String, failure: DownloadFailure) {
        guard failure != .cancelled else { return }
        failureNotices.removeAll { $0.bookId == bookId }
        failureNotices.append(DownloadFailureNotice(bookId: bookId, title: title, failure: failure))
    }

    private func resumeContinuation(for bookId: UUID, result: Result<Void, Error>) {
        guard resumedContinuations.insert(bookId).inserted, let continuation = continuations.removeValue(forKey: bookId) else { return }
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    // MARK: - Watchdog

    /// Fails a download only after a whole interval passes without any of the
    /// book's files receiving bytes. Background sessions wait for connectivity
    /// on their own, so an offline download fails after 5–10 minutes.
    private func startWatchdog(for bookId: UUID) {
        let interval = stallTimeoutOverride ?? ImportDefaults.downloadStallTimeout
        let watchdog = Task { @MainActor [weak self] in
            var lastBytes: Int64 = -1
            while true {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, let tasks = self.activeTasks[bookId], !tasks.isEmpty else { return }
                let bytes = self.receivedBytes(for: bookId, tasks: tasks)
                if bytes > lastBytes {
                    lastBytes = bytes
                    continue
                }
                self.fail(bookId: bookId, failure: .serverUnreachable, keepResumeData: true)
                return
            }
        }
        registerTimeoutTask(watchdog, for: bookId)
    }

    private func receivedBytes(for bookId: UUID, tasks: [Int: URLSessionDownloadTask]) -> Int64 {
        let staged = manifests[bookId].map { manifest in
            (completedIndices[bookId] ?? []).reduce(Int64(0)) { $0 + (manifest.tracks[$1].size ?? 0) }
        } ?? 0
        return tasks.values.reduce(staged) { $0 + $1.countOfBytesReceived }
    }

    private func registerTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) { cancelTimeoutTask(for: bookId); timeoutTasks[bookId] = task }
    private func cancelTimeoutTask(for bookId: UUID) { timeoutTasks.removeValue(forKey: bookId)?.cancel() }

    // MARK: - Progress

    private func recordBytes(_ tag: DownloadTaskTag, written: Int64, expected: Int64) {
        guard isCurrent(tag), downloads[tag.bookId]?.isActive == true else { return }
        inFlightBytes[tag.bookId, default: [:]][tag.trackIndex] = written
        if expected > 0 {
            inFlightFractions[tag.bookId, default: [:]][tag.trackIndex] = min(1, Double(written) / Double(expected))
        }
        publishProgress(for: tag.bookId)
    }

    /// Progress across all files, weighted by file size when every size is
    /// known and by file count otherwise.
    private func publishProgress(for bookId: UUID, force: Bool = false) {
        guard let manifest = manifests[bookId], var state = downloads[bookId] else { return }
        let completed = completedIndices[bookId] ?? []
        let sizes = manifest.tracks.map(\.size)
        let knownTotal = sizes.reduce(Int64(0)) { $0 + ($1 ?? 0) }
        let progress: Double
        if sizes.allSatisfy({ $0 != nil }), knownTotal > 0 {
            let total = knownTotal
            let done = completed.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            let inFlight = (inFlightBytes[bookId] ?? [:]).filter { !completed.contains($0.key) }.values.reduce(0, +)
            progress = Double(done + inFlight) / Double(total)
        } else {
            let inFlight = (inFlightFractions[bookId] ?? [:]).filter { !completed.contains($0.key) }.values.reduce(0, +)
            progress = (Double(completed.count) + inFlight) / Double(max(1, manifest.tracks.count))
        }
        let clamped = min(1, max(0, progress))
        let now = Date()
        if !force, let last = lastProgressPublish[bookId],
           now.timeIntervalSince(last.date) < 0.25, abs(clamped - last.progress) < 0.005 {
            return
        }
        lastProgressPublish[bookId] = (now, clamped)
        state.progress = clamped
        state.completedTracks = completed.count
        state.totalTracks = manifest.tracks.count
        downloads[bookId] = state
    }

    // MARK: - Task events

    /// Whether a task belongs to the book's current download attempt. After a
    /// relaunch the staged manifest is loaded on demand.
    private func isCurrent(_ tag: DownloadTaskTag) -> Bool {
        if let manifest = manifests[tag.bookId] { return manifest.attempt == tag.attempt }
        guard let manifest = try? DownloadStaging.readManifest(for: tag.bookId), manifest.attempt == tag.attempt else { return false }
        manifests[tag.bookId] = manifest
        completedIndices[tag.bookId] = Set(manifest.tracks.indices).subtracting(DownloadStaging.missingTrackIndices(for: manifest))
        return true
    }

    private func trackFinished(_ tag: DownloadTaskTag) {
        guard isCurrent(tag), let manifest = manifests[tag.bookId] else { return }
        activeTasks[tag.bookId]?[tag.trackIndex] = nil
        inFlightBytes[tag.bookId]?[tag.trackIndex] = nil
        inFlightFractions[tag.bookId]?[tag.trackIndex] = nil
        completedIndices[tag.bookId, default: []].insert(tag.trackIndex)

        let state = downloads[tag.bookId]
        switch state?.failure {
        case .some(.interrupted), .none:
            // A file that finished while the app wasn't running (or right after
            // it was reported interrupted) resumes the book's progress.
            if state == nil || state?.failure == .interrupted {
                interruptionChecks.removeValue(forKey: tag.bookId)?.cancel()
                var resumed = state ?? DownloadState(bookId: tag.bookId, progress: 0, status: .downloading)
                resumed.status = .downloading
                downloads[tag.bookId] = resumed
            }
        case .some:
            // The download already failed for another reason; keep the file
            // staged for a retry but don't revive the download.
            return
        }
        publishProgress(for: tag.bookId, force: true)

        if DownloadStaging.missingTrackIndices(for: manifest).isEmpty {
            finalize(bookId: tag.bookId, notify: true)
        }
    }

    private func handleTaskError(_ tag: DownloadTaskTag, error: Error, reason: CancelReason?, resumeData: Data?, cancelledBySystem: Bool) {
        guard isCurrent(tag) else { return }
        if let resumeData {
            DownloadStaging.saveResumeData(resumeData, bookID: tag.bookId, trackIndex: tag.trackIndex)
        }
        switch reason {
        case .user, .sibling, .stalled:
            // The app cancelled this task and already updated the book.
            return
        case nil:
            break
        }
        if cancelledBySystem || (error as? URLError)?.code == .cancelled {
            // The system cancelled the task (for example the app was force-quit).
            // Keep the staged files so a retry fetches only what's missing.
            fail(bookId: tag.bookId, failure: .interrupted)
            return
        }
        fail(bookId: tag.bookId, failure: DownloadFailure.classify(error))
    }

    // MARK: - Finalizing

    /// Moves a fully staged book into the remote cache and marks it downloaded.
    /// Runs synchronously on the main actor from the database fetch to the
    /// save, so no cleanup can run while the folder is moved but not yet
    /// recorded.
    @discardableResult
    private func finalize(bookId: UUID, notify: Bool) -> Result<Void, DownloadFailure> {
        guard !finalizing.contains(bookId) else { return .success(()) }
        guard let container = modelContainers[bookId] ?? configuredContainer else {
            pendingFinalizations.insert(bookId)
            return .success(())
        }
        finalizing.insert(bookId)
        defer { finalizing.remove(bookId) }

        #if canImport(UIKit)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "StoryCast.FinalizeDownload")
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        #endif

        let result = Self.moveIntoCache(bookId: bookId, container: container, stagingRoot: DownloadStaging.root)
        switch result {
        case .success:
            cancelTimeoutTask(for: bookId)
            interruptionChecks.removeValue(forKey: bookId)?.cancel()
            let total = manifests[bookId]?.tracks.count ?? 0
            activeTasks[bookId] = nil
            manifests[bookId] = nil
            completedIndices[bookId] = nil
            inFlightBytes[bookId] = nil
            inFlightFractions[bookId] = nil
            lastProgressPublish[bookId] = nil
            modelContainers.removeValue(forKey: bookId)
            pendingFinalizations.remove(bookId)
            downloads[bookId] = DownloadState(bookId: bookId, progress: 1, status: .completed, completedTracks: total, totalTracks: total)
            resumeContinuation(for: bookId, result: .success(()))
            AppLogger.sync.info("Download completed for book \(bookId, privacy: .private)")
        case .failure(let failure):
            fail(bookId: bookId, failure: failure, notify: notify && failure != .notFound)
        }
        return result
    }

    private static func moveIntoCache(bookId: UUID, container: ModelContainer, stagingRoot: URL) -> Result<Void, DownloadFailure> {
        let fileManager = FileManager.default
        guard var manifest = try? DownloadStaging.readManifest(for: bookId, root: stagingRoot) else {
            return .failure(.invalidResponse)
        }
        guard DownloadStaging.missingTrackIndices(for: manifest, root: stagingRoot).isEmpty else {
            return .failure(.interrupted)
        }
        let stagingFolder = DownloadStaging.folder(for: bookId, root: stagingRoot)
        for track in manifest.tracks {
            // Drop stale resume data before the folder becomes a download.
            try? fileManager.removeItem(at: DownloadStaging.resumeDataURL(for: bookId, trackIndex: track.index, root: stagingRoot))
        }
        manifest.completedAt = Date()
        do {
            try DownloadStaging.writeManifest(manifest, root: stagingRoot)
        } catch {
            return .failure(DownloadFailure.classify(error))
        }
        try? StorageManager.applyDownloadFolderAttributes(to: stagingFolder)

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookId })
        descriptor.fetchLimit = 1
        guard let book = try? context.fetch(descriptor).first,
              book.isRemote,
              book.remoteItemId == manifest.remoteItemId else {
            // The book was deleted (or is now a different item) while downloading.
            DownloadStaging.removeFolder(for: bookId, root: stagingRoot)
            return .failure(.notFound)
        }

        // Never replace files the player is reading.
        let player = AudioPlayerService.shared
        if player.currentBookID == bookId, player.currentSource?.isLocal == true {
            player.unload()
        }

        let folderName = RemoteDownloadLayout.folderName(for: bookId)
        let cacheRoot = StorageManager.shared.remoteAudioCacheDirectoryURL
        let destination = RemoteDownloadLayout.folderURL(named: folderName, cacheRoot: cacheRoot)
        let replacedURL = stagingRoot.appendingPathComponent("\(bookId.uuidString).replaced-\(UUID().uuidString)", isDirectory: true)
        var didReplace = false
        do {
            try DownloadStaging.withStagingLocked {
                try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    // Swap atomically, then set the old download aside, so a crash
                    // never leaves the book without a complete folder.
                    try swapItems(stagingFolder, destination)
                    try fileManager.moveItem(at: stagingFolder, to: replacedURL)
                    didReplace = true
                } else {
                    try fileManager.moveItem(at: stagingFolder, to: destination)
                }
            }
        } catch {
            return .failure(DownloadFailure.classify(error))
        }

        let previousPath = book.localCachePath
        book.isDownloaded = true
        book.localCachePath = folderName
        do {
            if let previousPath, previousPath != folderName {
                _ = try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: previousPath, in: context)
            }
            // A cleanup still pending from an earlier removal must not delete
            // the new download.
            let staleEntries = try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).filter {
                $0.locationRaw == CleanupLocation.remoteAudioCache.rawValue && $0.relativePath == folderName
            }
            staleEntries.forEach(context.delete)
            guard book.isValid else { throw DownloadFailure.invalidResponse }
            try context.save()
        } catch {
            context.rollback()
            DownloadStaging.withStagingLocked {
                try? fileManager.moveItem(at: destination, to: stagingFolder)
                if didReplace {
                    try? fileManager.moveItem(at: replacedURL, to: destination)
                }
            }
            return .failure(DownloadFailure.classify(error))
        }

        if didReplace {
            try? RemoteDownloadLayout.trashFolder(at: replacedURL)
        }
        StorageCleanupCoordinator.drainPendingCleanup(in: context)
        return .success(())
    }

    private nonisolated static func swapItems(_ first: URL, _ second: URL) throws {
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath -> Int32 in
                guard let firstPath, let secondPath else { return -1 }
                return renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - Relaunch

    /// Matches background tasks and staged files to books after a relaunch.
    func reconcile(tasks: [URLSessionTask], stagingRoot: URL = DownloadStaging.root, now: Date = Date()) {
        var liveTasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
        for case let task as URLSessionDownloadTask in tasks {
            guard let tag = DownloadTaskTag.decode(task.taskDescription),
                  let manifest = try? DownloadStaging.readManifest(for: tag.bookId, root: stagingRoot),
                  manifest.attempt == tag.attempt,
                  manifest.tracks.indices.contains(tag.trackIndex) else {
                // An older app's single-file download, or a task whose book is gone.
                recordCancel(task, reason: .user)
                task.cancel()
                continue
            }
            manifests[tag.bookId] = manifest
            liveTasks[tag.bookId, default: [:]][tag.trackIndex] = task
        }

        for (bookId, tasks) in liveTasks where activeTasks[bookId] == nil {
            guard let manifest = manifests[bookId] else { continue }
            let missing = DownloadStaging.missingTrackIndices(for: manifest, root: stagingRoot)
            activeTasks[bookId] = tasks
            completedIndices[bookId] = Set(manifest.tracks.indices).subtracting(missing)
            downloads[bookId] = DownloadState(
                bookId: bookId,
                progress: 0,
                status: .downloading,
                completedTracks: manifest.tracks.count - missing.count,
                totalTracks: manifest.tracks.count
            )
            publishProgress(for: bookId, force: true)
            startWatchdog(for: bookId)
        }

        for bookId in DownloadStaging.stagedBookIDs(root: stagingRoot)
        where liveTasks[bookId] == nil && activeTasks[bookId] == nil && continuations[bookId] == nil {
            let manifest: RemoteDownloadManifest
            do {
                manifest = try DownloadStaging.readManifest(for: bookId, root: stagingRoot)
            } catch is DecodingError {
                DownloadStaging.removeFolder(for: bookId, root: stagingRoot)
                continue
            } catch {
                // Unreadable right now (e.g. protected data unavailable); retry next launch.
                continue
            }
            manifests[bookId] = manifest
            let missing = DownloadStaging.missingTrackIndices(for: manifest, root: stagingRoot)
            if missing.isEmpty {
                finalize(bookId: bookId, notify: true)
            } else if now.timeIntervalSince(manifest.createdAt) > 14 * 24 * 60 * 60 {
                DownloadStaging.removeFolder(for: bookId, root: stagingRoot)
                manifests[bookId] = nil
            } else {
                completedIndices[bookId] = Set(manifest.tracks.indices).subtracting(missing)
                scheduleInterruptionCheck(for: bookId, manifest: manifest, missing: missing)
            }
        }

        sweepReplacedFolders(stagingRoot: stagingRoot)
        sweepUnreferencedDownloadFolders()
    }

    /// A book with staged files but no running tasks was interrupted (for
    /// example force-quit). Report it after a grace period, so files that
    /// finished while the app wasn't running can still arrive first.
    private func scheduleInterruptionCheck(for bookId: UUID, manifest: RemoteDownloadManifest, missing: [Int]) {
        interruptionChecks.removeValue(forKey: bookId)?.cancel()
        interruptionChecks[bookId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.interruptionGracePeriod ?? 10) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activeTasks[bookId] == nil, self.continuations[bookId] == nil,
                  !DownloadStaging.missingTrackIndices(for: manifest).isEmpty else { return }
            self.interruptionChecks[bookId] = nil
            self.downloads[bookId] = DownloadState(
                bookId: bookId,
                progress: 0,
                status: .failed(DownloadFailure.interrupted),
                completedTracks: manifest.tracks.count - missing.count,
                totalTracks: manifest.tracks.count
            )
            self.publishProgress(for: bookId, force: true)
            self.postNotice(bookId: bookId, title: manifest.title, failure: .interrupted)
        }
    }

    private func sweepReplacedFolders(stagingRoot: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.contains(".replaced-") {
            try? RemoteDownloadLayout.trashFolder(at: entry)
        }
    }

    /// A `<UUID>_remote` folder no book refers to is left over from a crash
    /// between moving it into place and saving the book. Adopt it when it is a
    /// complete download of that book; otherwise remove it.
    private func sweepUnreferencedDownloadFolders() {
        guard let container = configuredContainer else { return }
        let cacheRoot = StorageManager.shared.remoteAudioCacheDirectoryURL
        let entries = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        let folderNames = entries.map(\.lastPathComponent).filter(RemoteDownloadLayout.isDownloadFolderName)
        guard !folderNames.isEmpty else { return }

        let context = ModelContext(container)
        guard let books = try? context.fetch(FetchDescriptor<Book>()),
              let pendingCleanups = try? context.fetch(FetchDescriptor<StorageCleanupJournalEntry>()) else { return }
        let referenced = Set(books.compactMap(\.localCachePath))
        let pendingPaths = Set(pendingCleanups.filter { $0.locationRaw == CleanupLocation.remoteAudioCache.rawValue }.map(\.relativePath))
        var changed = false

        for name in folderNames where !referenced.contains(name) && !pendingPaths.contains(name) {
            guard let bookId = UUID(uuidString: String(name.dropLast(RemoteDownloadLayout.folderSuffix.count))),
                  !finalizing.contains(bookId) else { continue }
            let book = books.first { $0.id == bookId }
            if let book, book.isRemote,
               case .folder(_, let manifest) = RemoteDownloadLayout.resolve(localCachePath: name, cacheRoot: cacheRoot, expectedBookID: bookId),
               manifest.remoteItemId == book.remoteItemId,
               !Self.hasValidDownload(book, cacheRoot: cacheRoot) {
                if let previous = book.localCachePath {
                    _ = try? StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: previous, in: context)
                }
                book.isDownloaded = true
                book.localCachePath = name
                changed = true
            } else {
                try? RemoteDownloadLayout.trashFolder(at: RemoteDownloadLayout.folderURL(named: name, cacheRoot: cacheRoot))
            }
        }
        if changed {
            do {
                try context.save()
                StorageCleanupCoordinator.drainPendingCleanup(in: context)
            } catch {
                context.rollback()
            }
        }
    }

    private static func hasValidDownload(_ book: Book, cacheRoot: URL) -> Bool {
        guard book.isDownloaded, let path = book.localCachePath else { return false }
        switch RemoteDownloadLayout.resolve(localCachePath: path, cacheRoot: cacheRoot, expectedBookID: book.id) {
        case .legacyFile, .folder, .unreadable: return true
        case .missing, .invalid: return false
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Tasks without a tag belong to an older app version; the system
        // deletes their file when this method returns.
        guard let tag = DownloadTaskTag.decode(downloadTask.taskDescription) else { return }

        if let response = downloadTask.response as? HTTPURLResponse {
            guard (200...299).contains(response.statusCode) else {
                let failure = DownloadFailure.classify(httpStatus: response.statusCode)
                Task { @MainActor [weak self] in self?.handleTaskError(tag, error: failure, reason: nil, resumeData: nil, cancelledBySystem: false) }
                return
            }
            if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !contentType.hasPrefix("audio/") && !contentType.hasPrefix("application/octet-stream") && !contentType.hasPrefix("video/") {
                AppLogger.sync.warning("Rejecting download with unexpected Content-Type: \(contentType, privacy: .private)")
                Task { @MainActor [weak self] in
                    self?.handleTaskError(tag, error: DownloadFailure.invalidResponse, reason: nil, resumeData: nil, cancelledBySystem: false)
                }
                return
            }
        }

        // `location` is deleted when this method returns, so the file must be
        // moved into staging right here, not after hopping to the main actor.
        switch DownloadStaging.storeFinishedDownload(from: location, tag: tag) {
        case .stored:
            Task { @MainActor [weak self] in self?.trackFinished(tag) }
        case .discarded:
            break
        case .sizeMismatch:
            Task { @MainActor [weak self] in
                self?.handleTaskError(tag, error: DownloadFailure.fileChangedOnServer, reason: nil, resumeData: nil, cancelledBySystem: false)
            }
        case .failed(let message):
            let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: message])
            Task { @MainActor [weak self] in
                self?.handleTaskError(tag, error: error, reason: nil, resumeData: nil, cancelledBySystem: false)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = DownloadTaskTag.decode(downloadTask.taskDescription) else { return }
        if totalBytesWritten > RemoteDownloadPlanner.maxTrackBytes || totalBytesExpectedToWrite > RemoteDownloadPlanner.maxTrackBytes {
            recordCancel(downloadTask, reason: .sibling)
            downloadTask.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(tag) else { return }
                self.fail(bookId: tag.bookId, failure: .fileTooLarge)
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = progressThrottle.withLock { lastReports -> Bool in
            if let last = lastReports[downloadTask.taskIdentifier], now - last < 0.25 { return false }
            lastReports[downloadTask.taskIdentifier] = now
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor [weak self] in
            self?.recordBytes(tag, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let reason = cancelReasons.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        progressThrottle.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
        guard let error, let tag = DownloadTaskTag.decode(task.taskDescription) else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelledBySystem = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil
        Task { @MainActor [weak self] in
            self?.handleTaskError(tag, error: error, reason: reason, resumeData: resumeData, cancelledBySystem: cancelledBySystem)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Snapshot the keys before mutating the dict to avoid undefined
            // behavior from mutating-while-iterating.
            for identifier in Array(self.backgroundCompletionHandlers.keys) {
                guard let completionHandler = self.backgroundCompletionHandlers.removeValue(forKey: identifier) else { continue }
                AppLogger.sync.info("All background tasks finished for session \(identifier, privacy: .private) — calling system completion handler")
                completionHandler()
            }
        }
    }
}

#if DEBUG
extension DownloadManager {
    var debugTimeoutTaskCount: Int { timeoutTasks.count }
    var debugDownloadCount: Int { downloads.count }
    var debugBackgroundCompletionHandlerCount: Int { backgroundCompletionHandlers.count }
    var debugPendingFinalizationCount: Int { pendingFinalizations.count }
    func debugActiveTaskCount(for bookId: UUID) -> Int { activeTasks[bookId]?.count ?? 0 }

    /// Finalizes a one-file download from `localURL`, like the pre-folder API.
    func debugFinishDownload(bookId: UUID, localURL: URL, fileExtension: String, container: ModelContainer) async {
        let size = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber)?.int64Value
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookId })
        descriptor.fetchLimit = 1
        let book = try? context.fetch(descriptor).first
        let manifest = RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: bookId,
            remoteItemId: book?.remoteItemId ?? "",
            serverId: book?.serverId,
            attempt: UUID(),
            title: book?.title ?? "",
            tracks: [.init(index: 0, fileName: RemoteDownloadManifest.trackFileName(index: 0, ext: fileExtension), startOffset: 0, duration: 1, size: size, ino: nil, ext: fileExtension, mimeType: nil)],
            chapters: [],
            createdAt: Date(),
            completedAt: nil
        )
        do {
            try DownloadStaging.prepare(manifest)
            try FileManager.default.moveItem(at: localURL, to: DownloadStaging.folder(for: bookId).appendingPathComponent(manifest.tracks[0].fileName))
        } catch {
            return
        }
        modelContainers[bookId] = container
        manifests[bookId] = manifest
        if case .failure = finalize(bookId: bookId, notify: false) {
            DownloadStaging.removeFolder(for: bookId)
        }
    }

    func debugRegisterTrackedDownload(bookId: UUID, timeoutTask: Task<Void, Never>? = nil) {
        downloads[bookId] = DownloadState(bookId: bookId, progress: 0, status: .downloading)
        if let timeoutTask { registerTimeoutTask(timeoutTask, for: bookId) }
    }

    /// Tracks a download of `manifest` whose tasks were created elsewhere
    /// (tests use unstarted tasks from an ephemeral session).
    func debugRegisterDownload(manifest: RemoteDownloadManifest, tasks: [Int: URLSessionDownloadTask], container: ModelContainer) {
        manifests[manifest.bookId] = manifest
        modelContainers[manifest.bookId] = container
        activeTasks[manifest.bookId] = tasks
        completedIndices[manifest.bookId] = Set(manifest.tracks.indices).subtracting(DownloadStaging.missingTrackIndices(for: manifest))
        downloads[manifest.bookId] = DownloadState(bookId: manifest.bookId, progress: 0, status: .downloading, totalTracks: manifest.tracks.count)
    }

    func debugTrackFinished(_ tag: DownloadTaskTag) { trackFinished(tag) }
    func debugRecordBytes(_ tag: DownloadTaskTag, written: Int64, expected: Int64) { recordBytes(tag, written: written, expected: expected) }

    func debugHandleTaskError(_ tag: DownloadTaskTag, error: Error, reason: CancelReason?, cancelledBySystem: Bool = false) {
        handleTaskError(tag, error: error, reason: reason, resumeData: nil, cancelledBySystem: cancelledBySystem)
    }

    func debugSetStallTimeout(_ interval: TimeInterval?) { stallTimeoutOverride = interval }
    func debugSetInterruptionGracePeriod(_ interval: TimeInterval) { interruptionGracePeriod = interval }
    func debugStartWatchdog(for bookId: UUID) { startWatchdog(for: bookId) }
    func debugOverrideAPI(_ api: AudiobookshelfAPI?) { apiOverride = api }
    func debugSetConfiguredContainer(_ container: ModelContainer?) { configuredContainer = container }
    func debugClearFailureNotices() { failureNotices.removeAll() }

    func debugMarkDownloadCompleted(bookId: UUID) {
        downloads[bookId]?.status = .completed
        downloads[bookId]?.progress = 1.0
    }

    func debugResetState() {
        for timeoutTask in timeoutTasks.values { timeoutTask.cancel() }
        for check in interruptionChecks.values { check.cancel() }
        timeoutTasks.removeAll(); interruptionChecks.removeAll(); downloads.removeAll(); continuations.removeAll()
        resumedContinuations.removeAll(); activeTasks.removeAll(); manifests.removeAll(); completedIndices.removeAll()
        inFlightBytes.removeAll(); inFlightFractions.removeAll(); lastProgressPublish.removeAll()
        modelContainers.removeAll(); backgroundCompletionHandlers.removeAll(); pendingFinalizations.removeAll()
        failureNotices.removeAll(); finalizing.removeAll(); stallTimeoutOverride = nil; apiOverride = nil
        interruptionGracePeriod = 10
    }

    func debugRegisterTimeoutTask(_ task: Task<Void, Never>, for bookId: UUID) { registerTimeoutTask(task, for: bookId) }
    func debugCancelTimeoutTask(for bookId: UUID) { cancelTimeoutTask(for: bookId) }
}
#endif
