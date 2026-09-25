import Foundation
import SwiftData
import XCTest
@testable import StoryCast

/// Drives DownloadManager's bookkeeping with unstarted tasks from an ephemeral
/// session and files placed directly into an isolated staging root.
nonisolated final class DownloadManagerTests: XCTestCase {
    private var stagingRoot: URL!
    private var createdCacheFolders: [URL] = []
    private let ephemeralSession = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManagerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        DownloadStaging.overrideRoot(stagingRoot)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        await MainActor.run {
            DownloadManager.shared.debugResetState()
            DownloadManager.shared.debugSetInterruptionGracePeriod(0.1)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            DownloadManager.shared.debugResetState()
            DownloadManager.shared.debugSetConfiguredContainer(nil)
            AudioPlayerService.shared.unload()
        }
        DownloadStaging.overrideRoot(nil)
        try? FileManager.default.removeItem(at: stagingRoot)
        for folder in createdCacheFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        createdCacheFolders.removeAll()
    }

    // MARK: - Finalize

    @MainActor
    func testCompletingEveryFileMovesFolderIntoCacheAndMarksBookDownloaded() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [0])
        let tasks = makeTasks(manifest, indices: [1])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: tasks, container: container)

        try storeFile(manifest, index: 1, contents: "abcde")
        DownloadManager.shared.debugTrackFinished(tag(manifest, 1))

        let folderName = RemoteDownloadLayout.folderName(for: book.id)
        let destination = StorageManager.shared.remoteDownloadFolderURL(named: folderName)
        createdCacheFolders.append(destination)
        let saved = try fetchBook(book.id, in: container)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertEqual(saved.localCachePath, folderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
        guard case .folder(_, let finished) = RemoteDownloadLayout.resolve(
            localCachePath: folderName,
            cacheRoot: StorageManager.shared.remoteAudioCacheDirectoryURL,
            expectedBookID: book.id
        ) else { return XCTFail("Expected a valid download folder") }
        XCTAssertNotNil(finished.completedAt)
        XCTAssertEqual(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        guard case .completed? = DownloadManager.shared.downloads[book.id]?.status else { return XCTFail("Expected completed") }
    }

    @MainActor
    func testFinalizeQueuesCleanupOfOlderSingleFileDownload() async throws {
        let container = try makeContainer()
        let legacyName = "\(UUID().uuidString)_remote.m4b"
        let legacyURL = StorageManager.shared.remoteAudioCacheURL(for: legacyName)
        try Data("old".utf8).write(to: legacyURL)
        createdCacheFolders.append(legacyURL)
        let book = try insertBook(in: container, isDownloaded: true, localCachePath: legacyName)
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)
        createdCacheFolders.append(StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id)))

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))

        XCTAssertEqual(try fetchBook(book.id, in: container).localCachePath, RemoteDownloadLayout.folderName(for: book.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @MainActor
    func testFailedSaveRestoresEverything() async throws {
        let container = try makeContainer()
        let legacyName = "\(UUID().uuidString)_remote.m4b"
        let legacyURL = StorageManager.shared.remoteAudioCacheURL(for: legacyName)
        try Data("old".utf8).write(to: legacyURL)
        createdCacheFolders.append(legacyURL)
        // A blank title makes the book invalid, so the save fails.
        let book = try insertBook(in: container, title: "", isDownloaded: true, localCachePath: legacyName)
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)
        let destination = StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id))
        createdCacheFolders.append(destination)

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))

        let saved = try fetchBook(book.id, in: container)
        XCTAssertEqual(saved.localCachePath, legacyName)
        XCTAssertEqual(try Data(contentsOf: legacyURL), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(DownloadStaging.missingTrackIndices(for: manifest).isEmpty, "Staged files are kept for a retry")
        XCTAssertNotNil(DownloadManager.shared.downloads[book.id]?.failure)
    }

    @MainActor
    func testRedownloadReplacesExistingFolderAtomically() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let folderName = RemoteDownloadLayout.folderName(for: book.id)
        let destination = StorageManager.shared.remoteDownloadFolderURL(named: folderName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old-marker"))
        createdCacheFolders.append(destination)
        book.isDownloaded = true
        book.localCachePath = folderName
        try book.modelContext?.save()
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-marker").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("0001.mp3").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).filter { $0.contains(".replaced-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    @MainActor
    func testFinalizeForDeletedBookDiscardsStagingSilently() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)
        let context = ModelContext(container)
        context.delete(try fetchBook(book.id, in: container, context: context))
        try context.save()

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
        XCTAssertTrue(DownloadManager.shared.failureNotices.isEmpty)
    }

    @MainActor
    func testPendingCleanupForTheFolderDoesNotDeleteNewDownload() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let folderName = RemoteDownloadLayout.folderName(for: book.id)
        let context = ModelContext(container)
        _ = try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: folderName, in: context)
        try context.save()
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)
        let destination = StorageManager.shared.remoteDownloadFolderURL(named: folderName)
        createdCacheFolders.append(destination)

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))
        StorageCleanupCoordinator.drainPendingCleanup(in: ModelContext(container))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
    }

    @MainActor
    func testFinalizingUnloadsPlayerReadingThatBooksFiles() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [:], container: container)
        createdCacheFolders.append(StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id)))
        let localFile = DownloadStaging.folder(for: book.id).appendingPathComponent("0001.mp3")
        AudioPlayerService.shared.load(source: .singleFile(url: localFile, duration: 10, bookID: book.id), title: "Playing", seekTo: 0)

        DownloadManager.shared.debugTrackFinished(tag(manifest, 0))

        XCTAssertNil(AudioPlayerService.shared.currentBookID)
    }

    // MARK: - Cancelling and failures

    @MainActor
    func testCancelStopsEveryFileAndRemovesStaging() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5, 6], storing: [0])
        let tasks = makeTasks(manifest, indices: [1, 2])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: tasks, container: container)

        DownloadManager.shared.cancelDownload(bookId: book.id)

        XCTAssertTrue(tasks.values.allSatisfy(isCancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
        XCTAssertNil(DownloadManager.shared.downloads[book.id])
        XCTAssertTrue(DownloadManager.shared.failureNotices.isEmpty)
    }

    @MainActor
    func testOneFileFailingStopsSiblingsKeepsFinishedFilesAndNotifies() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5, 6], storing: [0])
        let tasks = makeTasks(manifest, indices: [1, 2])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: tasks, container: container)

        DownloadManager.shared.debugHandleTaskError(tag(manifest, 1), error: DownloadFailure.forbidden, reason: nil)

        XCTAssertTrue(isCancelled(try XCTUnwrap(tasks[2])))
        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.failure, .forbidden)
        XCTAssertEqual(DownloadStaging.missingTrackIndices(for: manifest), [1, 2])
        XCTAssertEqual(DownloadManager.shared.failureNotices.map(\.failure), [.forbidden])
    }

    @MainActor
    func testSystemCancellationKeepsStagingAsInterrupted() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: makeTasks(manifest, indices: [1]), container: container)

        DownloadManager.shared.debugHandleTaskError(tag(manifest, 1), error: URLError(.cancelled), reason: nil, cancelledBySystem: true)

        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.failure, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
    }

    @MainActor
    func testCallbacksFromAnEarlierAttemptAreIgnored() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: makeTasks(manifest, indices: [0, 1]), container: container)
        let stale = DownloadTaskTag(bookId: book.id, attempt: UUID(), trackIndex: 0, ino: "1000", ext: "mp3")

        DownloadManager.shared.debugHandleTaskError(stale, error: URLError(.cancelled), reason: nil)
        DownloadManager.shared.debugTrackFinished(stale)

        XCTAssertTrue(DownloadManager.shared.downloads[book.id]?.isActive ?? false)
        XCTAssertEqual(DownloadManager.shared.debugActiveTaskCount(for: book.id), 2)
    }

    @MainActor
    func testCancellationsTheAppMadeAreNotFailures() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: makeTasks(manifest, indices: [0, 1]), container: container)

        DownloadManager.shared.debugHandleTaskError(tag(manifest, 0), error: URLError(.cancelled), reason: .sibling)

        XCTAssertTrue(DownloadManager.shared.downloads[book.id]?.isActive ?? false)
    }

    @MainActor
    func testProgressIsWeightedByFileSize() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [100, 300], storing: [0])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: makeTasks(manifest, indices: [1]), container: container)

        DownloadManager.shared.debugRecordBytes(tag(manifest, 1), written: 100, expected: 300)
        try await Task.sleep(nanoseconds: 300_000_000)
        DownloadManager.shared.debugRecordBytes(tag(manifest, 1), written: 150, expected: 300)

        let progress = try XCTUnwrap(DownloadManager.shared.downloads[book.id]?.progress)
        XCTAssertEqual(progress, 250.0 / 400.0, accuracy: 0.001)
    }

    @MainActor
    func testWatchdogFailsWhenNoFileReceivesBytes() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: makeTasks(manifest, indices: [0, 1]), container: container)
        DownloadManager.shared.debugSetStallTimeout(0.1)

        DownloadManager.shared.debugStartWatchdog(for: book.id)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.failure, .serverUnreachable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
    }

    // MARK: - Relaunch

    @MainActor
    func testCompleteStagingFinalizesAfterRelaunchWithoutCaller() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        _ = try stage(for: book, sizes: [4, 5], storing: [0, 1])
        DownloadManager.shared.debugSetConfiguredContainer(container)
        createdCacheFolders.append(StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id)))

        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)

        XCTAssertTrue(try fetchBook(book.id, in: container).isDownloaded)
    }

    @MainActor
    func testFinalizeWaitsForContainer() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        _ = try stage(for: book, sizes: [4], storing: [0])
        createdCacheFolders.append(StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id)))

        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)
        XCTAssertEqual(DownloadManager.shared.debugPendingFinalizationCount, 1)
        XCTAssertFalse(try fetchBook(book.id, in: container).isDownloaded)

        DownloadManager.shared.configure(container: container)
        XCTAssertTrue(try fetchBook(book.id, in: container).isDownloaded)
    }

    @MainActor
    func testIncompleteStagingWithoutTasksIsReportedInterrupted() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        _ = try stage(for: book, sizes: [4, 5], storing: [0])
        DownloadManager.shared.debugSetConfiguredContainer(container)

        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.failure, .interrupted)
        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.completedTracks, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
    }

    @MainActor
    func testLateFinishAfterInterruptedCompletesTheBook() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [0])
        DownloadManager.shared.debugSetConfiguredContainer(container)
        createdCacheFolders.append(StorageManager.shared.remoteDownloadFolderURL(named: RemoteDownloadLayout.folderName(for: book.id)))
        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)
        try await Task.sleep(nanoseconds: 400_000_000)

        try storeFile(manifest, index: 1, contents: "abcde")
        DownloadManager.shared.debugTrackFinished(tag(manifest, 1))

        XCTAssertTrue(try fetchBook(book.id, in: container).isDownloaded)
    }

    @MainActor
    func testRunningTasksAreReattachedAfterRelaunch() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let manifest = try stage(for: book, sizes: [4, 5], storing: [0])
        DownloadManager.shared.debugSetConfiguredContainer(container)
        let live = makeTasks(manifest, indices: [1])

        DownloadManager.shared.reconcile(tasks: Array(live.values), stagingRoot: stagingRoot)

        XCTAssertTrue(DownloadManager.shared.downloads[book.id]?.isActive ?? false)
        XCTAssertEqual(DownloadManager.shared.downloads[book.id]?.completedTracks, 1)
        XCTAssertEqual(DownloadManager.shared.debugActiveTaskCount(for: book.id), 1)
    }

    @MainActor
    func testUntaggedOrOrphanedTasksAreCancelled() async throws {
        let untagged = ephemeralSession.downloadTask(with: URL(string: "https://example.invalid/old")!)
        untagged.taskDescription = "m4b"
        let orphan = ephemeralSession.downloadTask(with: URL(string: "https://example.invalid/orphan")!)
        orphan.taskDescription = DownloadTaskTag(bookId: UUID(), attempt: UUID(), trackIndex: 0, ino: nil, ext: "mp3").encoded()

        DownloadManager.shared.reconcile(tasks: [untagged, orphan], stagingRoot: stagingRoot)

        XCTAssertTrue(isCancelled(untagged))
        XCTAssertTrue(isCancelled(orphan))
    }

    @MainActor
    func testStaleStagingAndReplacedFoldersAreSwept() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        var manifest = makeManifest(for: book, sizes: [4, 5])
        manifest.createdAt = Date(timeIntervalSinceNow: -15 * 24 * 60 * 60)
        try DownloadStaging.prepare(manifest)
        let replaced = stagingRoot.appendingPathComponent("\(UUID().uuidString).replaced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)

        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: book.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path))
    }

    @MainActor
    func testUnreferencedCompleteFolderIsAdoptedByItsBook() async throws {
        let container = try makeContainer()
        let book = try insertBook(in: container)
        let folderName = RemoteDownloadLayout.folderName(for: book.id)
        let destination = StorageManager.shared.remoteDownloadFolderURL(named: folderName)
        createdCacheFolders.append(destination)
        var manifest = makeManifest(for: book, sizes: [4])
        manifest.completedAt = Date()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("abcd".utf8).write(to: destination.appendingPathComponent("0001.mp3"))
        try manifest.encoded().write(to: destination.appendingPathComponent(RemoteDownloadManifest.fileName))
        DownloadManager.shared.debugSetConfiguredContainer(container)

        DownloadManager.shared.reconcile(tasks: [], stagingRoot: stagingRoot)

        let saved = try fetchBook(book.id, in: container)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertEqual(saved.localCachePath, folderName)
    }

    // MARK: - Helpers

    /// A cancelled task moves from `.canceling` to `.completed` on its own.
    private func isCancelled(_ task: URLSessionTask) -> Bool {
        task.state == .canceling || task.state == .completed
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    @MainActor
    private func insertBook(in container: ModelContainer, title: String = "Remote", isDownloaded: Bool = false, localCachePath: String? = nil) throws -> Book {
        let context = container.mainContext
        let book = Book(title: title, duration: 20, isRemote: true, remoteItemId: "item-\(UUID().uuidString)", isDownloaded: isDownloaded, localCachePath: localCachePath)
        context.insert(book)
        try context.save()
        return book
    }

    @MainActor
    private func fetchBook(_ id: UUID, in container: ModelContainer, context: ModelContext? = nil) throws -> Book {
        let context = context ?? ModelContext(container)
        return try XCTUnwrap(try context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })).first)
    }

    @MainActor
    private func makeManifest(for book: Book, sizes: [Int64?]) -> RemoteDownloadManifest {
        RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: book.id,
            remoteItemId: book.remoteItemId ?? "",
            serverId: nil,
            attempt: UUID(),
            title: book.title,
            tracks: sizes.enumerated().map { index, size in
                .init(index: index, fileName: RemoteDownloadManifest.trackFileName(index: index, ext: "mp3"), startOffset: Double(index) * 10, duration: 10, size: size, ino: "\(1000 + index)", ext: "mp3", mimeType: "audio/mpeg")
            },
            chapters: [],
            createdAt: Date(),
            completedAt: nil
        )
    }

    /// Stages a download of `book` with the given file sizes, placing the
    /// files at `storing` (their contents are that many letters).
    @MainActor
    private func stage(for book: Book, sizes: [Int64], storing: [Int]) throws -> RemoteDownloadManifest {
        let manifest = makeManifest(for: book, sizes: sizes)
        try DownloadStaging.prepare(manifest)
        for index in storing {
            try storeFile(manifest, index: index, contents: String(repeating: "a", count: Int(sizes[index])))
        }
        return manifest
    }

    private func storeFile(_ manifest: RemoteDownloadManifest, index: Int, contents: String) throws {
        let url = stagingRoot.appendingPathComponent("incoming-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: url, tag: tag(manifest, index)), .stored)
    }

    private func tag(_ manifest: RemoteDownloadManifest, _ index: Int) -> DownloadTaskTag {
        DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: index, ino: manifest.tracks[index].ino, ext: "mp3")
    }

    private func makeTasks(_ manifest: RemoteDownloadManifest, indices: [Int]) -> [Int: URLSessionDownloadTask] {
        Dictionary(uniqueKeysWithValues: indices.map { index in
            let task = ephemeralSession.downloadTask(with: URL(string: "https://example.invalid/\(index)")!)
            task.taskDescription = tag(manifest, index).encoded()
            return (index, task)
        })
    }
}
