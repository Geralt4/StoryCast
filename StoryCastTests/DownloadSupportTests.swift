import Foundation
import XCTest
@testable import StoryCast

nonisolated final class DownloadSupportTests: XCTestCase {
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadSupportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stagingRoot)
        super.tearDown()
    }

    // MARK: - Tags

    func testTagRoundTripsThroughTaskDescription() {
        let tag = DownloadTaskTag(bookId: UUID(), attempt: UUID(), trackIndex: 2, ino: "123", ext: "mp3")
        XCTAssertEqual(DownloadTaskTag.decode(tag.encoded()), tag)
    }

    func testOlderSingleFileTaskDescriptionIsNotATag() {
        XCTAssertNil(DownloadTaskTag.decode("m4b"))
        XCTAssertNil(DownloadTaskTag.decode(nil))
        XCTAssertNil(DownloadTaskTag.decode("{\"garbage\":1}"))
    }

    func testTagWithUnsafeExtensionIsRejected() {
        let tag = DownloadTaskTag(bookId: UUID(), attempt: UUID(), trackIndex: 0, ino: nil, ext: "../mp3")
        XCTAssertNil(DownloadTaskTag.decode(tag.encoded()))
    }

    // MARK: - Planner

    func testManifestFromRecordedItemListsEveryFileInOrder() throws {
        let item = try ABSFixtures.libraryItem("abs-item-mp3-multi")
        let bookID = UUID()
        let manifest = try RemoteDownloadPlanner.makeManifest(item: item, bookID: bookID, serverID: nil, title: "Multi", attempt: UUID(), now: Date())

        XCTAssertEqual(manifest.bookId, bookID)
        XCTAssertEqual(manifest.remoteItemId, item.id)
        XCTAssertEqual(manifest.tracks.map(\.fileName), ["0001.mp3", "0002.mp3", "0003.mp3"])
        XCTAssertEqual(manifest.tracks.map(\.startOffset), [0, 95, 156])
        XCTAssertEqual(manifest.tracks.map(\.duration), [95, 61, 127])
        XCTAssertTrue(manifest.tracks.allSatisfy { ($0.size ?? 0) > 0 && $0.ino != nil })
        XCTAssertEqual(manifest.chapters.count, 3)
        XCTAssertNil(manifest.completedAt)
    }

    func testM4AItemUsesM4AExtension() throws {
        let manifest = try RemoteDownloadPlanner.makeManifest(item: ABSFixtures.libraryItem("abs-item-m4a-multi"), bookID: UUID(), serverID: nil, title: "M4A", attempt: UUID(), now: Date())
        XCTAssertEqual(manifest.tracks.map(\.ext), ["m4a", "m4a", "m4a"])
    }

    func testExtensionFallsBackToFileNameThenMimeType() {
        func track(ext: String?, filename: String?, mime: String?) -> ABSAudioTrack {
            ABSAudioTrack(
                index: 1, startOffset: 0, duration: 1, title: nil, contentUrl: "/api/items/x/file/1",
                mimeType: mime, metadata: ABSFileMetadata(filename: filename, ext: ext, path: nil, size: nil),
                ino: "1", codec: nil
            )
        }
        XCTAssertEqual(RemoteDownloadPlanner.fileExtension(for: track(ext: ".MP3", filename: nil, mime: nil)), "mp3")
        XCTAssertEqual(RemoteDownloadPlanner.fileExtension(for: track(ext: nil, filename: "Part 1.flac", mime: nil)), "flac")
        XCTAssertEqual(RemoteDownloadPlanner.fileExtension(for: track(ext: nil, filename: nil, mime: "audio/mpeg")), "mp3")
        XCTAssertEqual(RemoteDownloadPlanner.fileExtension(for: track(ext: "../x", filename: nil, mime: nil)), "m4b")
    }

    func testFileLargerThanTwoGigabytesIsRejected() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ABSFixtures.data("abs-item-mp3-multi")) as? [String: Any])
        var media = try XCTUnwrap(json["media"] as? [String: Any])
        var tracks = try XCTUnwrap(media["tracks"] as? [[String: Any]])
        var metadata = try XCTUnwrap(tracks[1]["metadata"] as? [String: Any])
        metadata["size"] = 3_000_000_000
        tracks[1]["metadata"] = metadata
        media["tracks"] = tracks
        json["media"] = media
        let item = try JSONDecoder().decode(ABSLibraryItem.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertThrowsError(try RemoteDownloadPlanner.makeManifest(item: item, bookID: UUID(), serverID: nil, title: "Big", attempt: UUID(), now: Date())) {
            XCTAssertEqual($0 as? DownloadFailure, .fileTooLarge)
        }
    }

    // MARK: - Failures

    func testFailureClassification() {
        XCTAssertEqual(DownloadFailure.classify(URLError(.notConnectedToInternet)), .serverUnreachable)
        XCTAssertEqual(DownloadFailure.classify(URLError(.timedOut)), .serverUnreachable)
        XCTAssertEqual(DownloadFailure.classify(URLError(.serverCertificateUntrusted)), .untrustedCertificate)
        XCTAssertEqual(DownloadFailure.classify(URLError(.cannotWriteToFile)), .diskFull)
        XCTAssertEqual(DownloadFailure.classify(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(DownloadFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        XCTAssertEqual(DownloadFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), .diskFull)
        XCTAssertEqual(DownloadFailure.classify(APIError.httpError(statusCode: 403)), .forbidden)
        XCTAssertEqual(DownloadFailure.classify(APIError.networkError(URLError(.cannotConnectToHost))), .serverUnreachable)
        XCTAssertEqual(DownloadFailure.classify(httpStatus: 401), .unauthorized)
        XCTAssertEqual(DownloadFailure.classify(httpStatus: 404), .notFound)
        XCTAssertEqual(DownloadFailure.classify(httpStatus: 503), .serverError(503))
        XCTAssertFalse(DownloadFailure.diskFull.userMessage.isEmpty)
    }

    // MARK: - Staging

    func testStoringAcceptsOnlyTheCurrentAttemptAndServerFile() throws {
        let manifest = makeManifest(sizes: [4, 5])
        try DownloadStaging.prepare(manifest, root: stagingRoot)

        let good = DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: 0, ino: "1000", ext: "mp3")
        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("abcd"), tag: good, root: stagingRoot), .stored)

        let oldAttempt = DownloadTaskTag(bookId: manifest.bookId, attempt: UUID(), trackIndex: 1, ino: "1001", ext: "mp3")
        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("abcde"), tag: oldAttempt, root: stagingRoot), .discarded)

        let otherFile = DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: 1, ino: "9999", ext: "mp3")
        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("abcde"), tag: otherFile, root: stagingRoot), .discarded)

        XCTAssertEqual(DownloadStaging.missingTrackIndices(for: manifest, root: stagingRoot), [1])
    }

    func testStoringRejectsWrongSize() throws {
        let manifest = makeManifest(sizes: [4])
        try DownloadStaging.prepare(manifest, root: stagingRoot)
        let tag = DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: 0, ino: "1000", ext: "mp3")

        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("too long"), tag: tag, root: stagingRoot), .sizeMismatch)
    }

    func testStoringWithoutStagingFolderIsDiscardedAndNeverCreatesFolders() throws {
        let manifest = makeManifest(sizes: [4])
        let tag = DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: 0, ino: "1000", ext: "mp3")

        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("abcd"), tag: tag, root: stagingRoot), .discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStaging.folder(for: manifest.bookId, root: stagingRoot).path))
    }

    func testRetryKeepsFilesOfSameServerFilesButDropsOthers() throws {
        let manifest = makeManifest(sizes: [4, 5])
        try DownloadStaging.prepare(manifest, root: stagingRoot)
        let tag = DownloadTaskTag(bookId: manifest.bookId, attempt: manifest.attempt, trackIndex: 0, ino: "1000", ext: "mp3")
        XCTAssertEqual(DownloadStaging.storeFinishedDownload(from: try tempFile("abcd"), tag: tag, root: stagingRoot), .stored)

        var retry = manifest
        retry.attempt = UUID()
        try DownloadStaging.prepare(retry, root: stagingRoot)
        XCTAssertEqual(DownloadStaging.missingTrackIndices(for: retry, root: stagingRoot), [1])

        var changed = retry
        changed.tracks[0].ino = "2000"
        changed.attempt = UUID()
        try DownloadStaging.prepare(changed, root: stagingRoot)
        XCTAssertEqual(DownloadStaging.missingTrackIndices(for: changed, root: stagingRoot), [0, 1])
    }

    func testResumeDataIsTakenOnce() throws {
        let manifest = makeManifest(sizes: [4])
        try DownloadStaging.prepare(manifest, root: stagingRoot)
        DownloadStaging.saveResumeData(Data("resume".utf8), bookID: manifest.bookId, trackIndex: 0, root: stagingRoot)

        XCTAssertEqual(DownloadStaging.takeResumeData(bookID: manifest.bookId, trackIndex: 0, root: stagingRoot), Data("resume".utf8))
        XCTAssertNil(DownloadStaging.takeResumeData(bookID: manifest.bookId, trackIndex: 0, root: stagingRoot))
    }

    // MARK: - Helpers

    private func tempFile(_ contents: String) throws -> URL {
        let url = stagingRoot.appendingPathComponent("download-\(UUID().uuidString).tmp")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeManifest(sizes: [Int64?]) -> RemoteDownloadManifest {
        RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: UUID(),
            remoteItemId: "item-1",
            serverId: nil,
            attempt: UUID(),
            title: "Test",
            tracks: sizes.enumerated().map { index, size in
                .init(index: index, fileName: RemoteDownloadManifest.trackFileName(index: index, ext: "mp3"), startOffset: Double(index) * 10, duration: 10, size: size, ino: "\(1000 + index)", ext: "mp3", mimeType: "audio/mpeg")
            },
            chapters: [],
            createdAt: Date(),
            completedAt: nil
        )
    }
}
