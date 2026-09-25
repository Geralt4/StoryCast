import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class DownloadStatusTests: XCTestCase {
    private var stagingRoot: URL!
    private let ephemeralSession = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadStatusTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        DownloadStaging.overrideRoot(stagingRoot)
        await MainActor.run { DownloadManager.shared.debugResetState() }
    }

    override func tearDown() async throws {
        await MainActor.run { DownloadManager.shared.debugResetState() }
        DownloadStaging.overrideRoot(nil)
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    @MainActor
    func testDisplayStates() throws {
        let manager = DownloadManager.shared
        let streaming = Book(title: "Streaming", duration: 10, isRemote: true)
        XCTAssertEqual(BookDownloadDisplayState(book: streaming), .streaming)

        let downloaded = Book(title: "Downloaded", duration: 10, isRemote: true, isDownloaded: true, localCachePath: "x_remote")
        XCTAssertEqual(BookDownloadDisplayState(book: downloaded), .downloaded)

        let active = Book(title: "Active", duration: 10, isRemote: true)
        manager.debugRegisterTrackedDownload(bookId: active.id)
        XCTAssertEqual(BookDownloadDisplayState(book: active), .downloading(progress: 0))

        let failed = Book(title: "Failed", duration: 10, isRemote: true)
        let failedTask = try register(failed)
        manager.debugHandleTaskError(failedTask, error: DownloadFailure.serverUnreachable, reason: nil)
        XCTAssertEqual(BookDownloadDisplayState(book: failed), .failed(.serverUnreachable))

        // A failed re-download of a book that is still downloaded shows as downloaded.
        let redownload = Book(title: "Redownload", duration: 10, isRemote: true, isDownloaded: true, localCachePath: "y_remote")
        manager.debugHandleTaskError(try register(redownload), error: DownloadFailure.serverUnreachable, reason: nil)
        XCTAssertEqual(BookDownloadDisplayState(book: redownload), .downloaded)
    }

    func testAccessibilityDescriptions() {
        XCTAssertEqual(BookDownloadDisplayState.downloading(progress: 0.456).accessibilityDescription, "Downloading, 46 percent")
        XCTAssertEqual(BookDownloadDisplayState.failed(.diskFull).accessibilityDescription, "Download failed")
    }

    @MainActor
    func testFailureNoticesQueueInOrderAndDismiss() throws {
        let manager = DownloadManager.shared
        let first = Book(title: "First", duration: 10, isRemote: true)
        let second = Book(title: "Second", duration: 10, isRemote: true)
        manager.debugHandleTaskError(try register(first), error: DownloadFailure.diskFull, reason: nil)
        manager.debugHandleTaskError(try register(second), error: DownloadFailure.forbidden, reason: nil)

        XCTAssertEqual(manager.failureNotices.map(\.title), ["First", "Second"])
        XCTAssertEqual(manager.failureNotices.map(\.failure), [.diskFull, .forbidden])
        XCTAssertEqual(manager.failureNotices.first?.message, DownloadFailure.diskFull.userMessage)

        manager.dismissFailureNotice(try XCTUnwrap(manager.failureNotices.first))
        XCTAssertEqual(manager.failureNotices.map(\.title), ["Second"])
    }

    @MainActor
    func testCancellingPostsNoNotice() throws {
        let manager = DownloadManager.shared
        let book = Book(title: "Cancelled", duration: 10, isRemote: true)
        _ = try register(book)

        manager.cancelDownload(bookId: book.id)

        XCTAssertTrue(manager.failureNotices.isEmpty)
    }

    @MainActor
    private func register(_ book: Book) throws -> DownloadTaskTag {
        let manifest = RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: book.id,
            remoteItemId: "item",
            serverId: nil,
            attempt: UUID(),
            title: book.title,
            tracks: [.init(index: 0, fileName: "0001.mp3", startOffset: 0, duration: 10, size: 4, ino: "1", ext: "mp3", mimeType: nil)],
            chapters: [],
            createdAt: Date(),
            completedAt: nil
        )
        try DownloadStaging.prepare(manifest)
        let tag = DownloadTaskTag(bookId: book.id, attempt: manifest.attempt, trackIndex: 0, ino: "1", ext: "mp3")
        let task = ephemeralSession.downloadTask(with: URL(string: "https://example.invalid/0")!)
        task.taskDescription = tag.encoded()
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        DownloadManager.shared.debugRegisterDownload(manifest: manifest, tasks: [0: task], container: container)
        return tag
    }
}

