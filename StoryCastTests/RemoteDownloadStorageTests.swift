import Foundation
import SwiftData
import XCTest
@testable import StoryCast

/// Folder downloads: manifest validation, resolution and cleanup.
nonisolated final class RemoteDownloadStorageTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Names

    func testFolderAndTrackNaming() {
        let bookID = UUID()
        let folder = RemoteDownloadLayout.folderName(for: bookID)
        XCTAssertEqual(folder, "\(bookID.uuidString)_remote")
        XCTAssertTrue(RemoteDownloadLayout.isDownloadFolderName(folder))
        XCTAssertFalse(RemoteDownloadLayout.isDownloadFolderName("\(bookID.uuidString)_remote.m4b"))
        XCTAssertFalse(RemoteDownloadLayout.isDownloadFolderName("not-a-uuid_remote"))
        XCTAssertEqual(RemoteDownloadManifest.trackFileName(index: 0, ext: "mp3"), "0001.mp3")
        XCTAssertTrue(RemoteDownloadLayout.isTrackFileName("0001.mp3"))
        XCTAssertTrue(RemoteDownloadLayout.isTrackFileName("12345.m4a"))
        XCTAssertFalse(RemoteDownloadLayout.isTrackFileName("../0001.mp3"))
        XCTAssertFalse(RemoteDownloadLayout.isTrackFileName("track.mp3"))
        XCTAssertFalse(RemoteDownloadLayout.isTrackFileName("0001.MP3"))
    }

    func testManifestRoundTrip() throws {
        let manifest = makeManifest(bookID: UUID(), sizes: [4, 5])
        XCTAssertEqual(try RemoteDownloadManifest.decode(manifest.encoded()), manifest)
    }

    // MARK: - Resolution

    func testValidFolderResolvesToMultiFileSourceWithFolderIdentity() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd", "abcde"])

        let resolution = RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID)

        guard case .folder(let url, let manifest) = resolution else { return XCTFail("Expected folder, got \(resolution)") }
        let source = try XCTUnwrap(manifest.playbackSource(folderURL: url))
        XCTAssertEqual(source.identityURL, url)
        XCTAssertEqual(source.trackURLs.map(\.lastPathComponent), ["0001.mp3", "0002.mp3"])
        XCTAssertEqual(source.timeline.duration, 30)
        XCTAssertEqual(source.bookID, bookID)
        XCTAssertTrue(source.isLocal)
        XCTAssertEqual(RemoteDownloadLayout.quickIdentityURL(localCachePath: folder.lastPathComponent, cacheRoot: root), url)
    }

    func testLegacyFileResolves() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let name = "\(bookID.uuidString)_remote.m4b"
        try Data("audio".utf8).write(to: root.appendingPathComponent(name))

        XCTAssertEqual(
            RemoteDownloadLayout.resolve(localCachePath: name, cacheRoot: root, expectedBookID: bookID),
            .legacyFile(root.appendingPathComponent(name))
        )
    }

    func testMissingDownloadResolvesToMissing() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        XCTAssertEqual(
            RemoteDownloadLayout.resolve(localCachePath: RemoteDownloadLayout.folderName(for: bookID), cacheRoot: root, expectedBookID: bookID),
            .missing
        )
        XCTAssertNil(RemoteDownloadLayout.quickIdentityURL(localCachePath: RemoteDownloadLayout.folderName(for: bookID), cacheRoot: root))
    }

    func testRejectsFolderOfAnotherBook() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd"])

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: UUID()))
    }

    func testRejectsManifestForAnotherBook() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        var manifest = makeManifest(bookID: UUID(), sizes: [4])
        manifest.bookId = UUID()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd"], manifest: manifest)

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
    }

    func testRejectsUnsafeDuplicateAndUnexpectedFileNames() throws {
        for badNames in [["../0001.mp3"], ["a/b.mp3"], ["\u{FF0E}\u{FF0E}"], ["0001.mp3", "0001.mp3"], ["track.mp3"]] {
            let bookID = UUID()
            let root = try makeCacheRoot()
            var manifest = makeManifest(bookID: bookID, sizes: badNames.map { _ in nil })
            for index in manifest.tracks.indices { manifest.tracks[index].fileName = badNames[index] }
            let folder = try writeDownload(bookID: bookID, root: root, contents: [], manifest: manifest)

            assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID), badNames.description)
        }
    }

    func testRejectsMissingTrackFile() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd", "abcde"])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("0002.mp3"))

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
    }

    func testRejectsTrackWithWrongSize() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let manifest = makeManifest(bookID: bookID, sizes: [4, 99])
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd", "abcde"], manifest: manifest)

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
    }

    func testRejectsSymlinkedTrack() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd", "abcde"])
        let track = folder.appendingPathComponent("0002.mp3")
        let outside = root.appendingPathComponent("outside.mp3")
        try Data("abcde".utf8).write(to: outside)
        try FileManager.default.removeItem(at: track)
        try FileManager.default.createSymbolicLink(at: track, withDestinationURL: outside)

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
    }

    func testRejectsIncompleteAndFutureManifests() throws {
        let bookID = UUID()
        var incomplete = makeManifest(bookID: bookID, sizes: [4])
        incomplete.completedAt = nil
        var future = makeManifest(bookID: bookID, sizes: [4])
        future.version = RemoteDownloadManifest.currentVersion + 1

        for manifest in [incomplete, future] {
            let root = try makeCacheRoot()
            let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd"], manifest: manifest)
            assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
        }
    }

    func testRejectsUndecodableManifest() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd"])
        try Data("not json".utf8).write(to: folder.appendingPathComponent(RemoteDownloadManifest.fileName))

        assertInvalid(RemoteDownloadLayout.resolve(localCachePath: folder.lastPathComponent, cacheRoot: root, expectedBookID: bookID))
    }

    // MARK: - Cleanup

    @MainActor
    func testCleanupRemovesRemoteDownloadFolder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let bookID = UUID()
        let folder = try writeDownload(bookID: bookID, root: StorageManager.shared.remoteAudioCacheDirectoryURL, contents: ["abcd"])
        tempDirectories.append(folder)

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: folder.lastPathComponent, in: context))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testCleanupKeepsReferencedRemoteDownloadFolder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let bookID = UUID()
        let folder = try writeDownload(bookID: bookID, root: StorageManager.shared.remoteAudioCacheDirectoryURL, contents: ["abcd"])
        tempDirectories.append(folder)
        context.insert(Book(id: bookID, title: "Downloaded", duration: 10, isRemote: true, isDownloaded: true, localCachePath: folder.lastPathComponent))
        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: folder.lastPathComponent, in: context))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testCleanupDiscardsOtherDirectoriesInRemoteCache() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let directory = StorageManager.shared.remoteAudioCacheDirectoryURL
            .appendingPathComponent("not-a-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        tempDirectories.append(directory)

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: directory.lastPathComponent, in: context))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testCleanupDiscardsSymlinkNamedLikeDownloadFolder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let target = try makeCacheRoot()
        let link = StorageManager.shared.remoteAudioCacheDirectoryURL
            .appendingPathComponent(RemoteDownloadLayout.folderName(for: UUID()), isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        tempDirectories.append(link)

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: link.lastPathComponent, in: context))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testDownloadFolderAttributesExcludeFromBackup() throws {
        let bookID = UUID()
        let root = try makeCacheRoot()
        let folder = try writeDownload(bookID: bookID, root: root, contents: ["abcd"])

        try StorageManager.applyDownloadFolderAttributes(to: folder)

        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    // MARK: - Helpers

    private func assertInvalid(_ resolution: RemoteDownloadLayout.Resolution, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid = resolution else {
            return XCTFail("Expected invalid, got \(resolution) \(message)", file: file, line: line)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    private func makeCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDownloadStorageTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectories.append(root)
        return root
    }

    private func makeManifest(bookID: UUID, sizes: [Int64?]) -> RemoteDownloadManifest {
        var offset = 0.0
        let tracks = sizes.enumerated().map { index, size -> RemoteDownloadManifest.Track in
            defer { offset += 10 + Double(index) * 10 }
            return RemoteDownloadManifest.Track(
                index: index,
                fileName: RemoteDownloadManifest.trackFileName(index: index, ext: "mp3"),
                startOffset: offset,
                duration: 10 + Double(index) * 10,
                size: size,
                ino: "\(1000 + index)",
                ext: "mp3",
                mimeType: "audio/mpeg"
            )
        }
        return RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: bookID,
            remoteItemId: "item-1",
            serverId: nil,
            attempt: UUID(),
            title: "Test",
            tracks: tracks,
            chapters: [.init(id: 0, start: 0, end: 10, title: "One")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @discardableResult
    private func writeDownload(bookID: UUID, root: URL, contents: [String], manifest: RemoteDownloadManifest? = nil) throws -> URL {
        let manifest = manifest ?? makeManifest(bookID: bookID, sizes: contents.map { Int64($0.utf8.count) })
        let folder = RemoteDownloadLayout.folderURL(named: RemoteDownloadLayout.folderName(for: bookID), cacheRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (track, content) in zip(manifest.tracks, contents) {
            try Data(content.utf8).write(to: folder.appendingPathComponent(track.fileName))
        }
        try manifest.encoded().write(to: folder.appendingPathComponent(RemoteDownloadManifest.fileName))
        return folder
    }
}
