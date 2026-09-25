import Foundation
import SwiftData
import XCTest
@testable import StoryCast

/// End-to-end tests against a real Audiobookshelf server. Skipped unless
/// STORYCAST_ABS_IT=1. Expects the test library described in ABSFixtures, and:
/// STORYCAST_ABS_URL (https), STORYCAST_ABS_USER, STORYCAST_ABS_PASSWORD, and
/// STORYCAST_ABS_ITEMS as JSON mapping "mp3", "m4a" and "m4b" to item IDs.
/// Run with -parallel-testing-enabled NO.
@MainActor
final class ABSIntegrationTests: XCTestCase {
    private struct Environment {
        let url: String
        let user: String
        let password: String
        let items: [String: String]
    }

    private var environment: Environment!
    private var container: ModelContainer!
    private var server: ABSServer!
    private var createdPaths: [URL] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["STORYCAST_ABS_IT"] == "1", "Integration tests run only with STORYCAST_ABS_IT=1")
        let itemsJSON = try XCTUnwrap(env["STORYCAST_ABS_ITEMS"])
        environment = Environment(
            url: try XCTUnwrap(env["STORYCAST_ABS_URL"]),
            user: try XCTUnwrap(env["STORYCAST_ABS_USER"]),
            password: try XCTUnwrap(env["STORYCAST_ABS_PASSWORD"]),
            items: try JSONDecoder().decode([String: String].self, from: Data(itemsJSON.utf8))
        )
        let login = try await AudiobookshelfAPI.shared.login(baseURL: environment.url, username: environment.user, password: environment.password)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let server = ABSServer(name: "Integration", url: environment.url, username: environment.user)
        try await AudiobookshelfAuth.shared.saveToken(login.user.token, for: server.normalizedURL)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        try await StorageManager.shared.setupDownloadStagingDirectory()
        container.mainContext.insert(server)
        try container.mainContext.save()
        DownloadManager.shared.configure(container: container)
        self.container = container
        self.server = server
    }

    override func tearDown() async throws {
        guard environment != nil else { return }
        AudioPlayerService.shared.unload()
        PlaybackSessionManager.shared.debugResetSession()
        PlaybackSessionManager.shared.debugClearSeeking()
        for path in createdPaths { try? FileManager.default.removeItem(at: path) }
        if let server {
            try? await AudiobookshelfAuth.shared.deleteToken(for: server.normalizedURL)
        }
    }

    // MARK: - Streaming

    @MainActor
    func testStreamingMultiFileMP3CrossesFilesAndSyncsWholeBookPosition() async throws {
        let book = try insertBook(kind: "mp3", duration: 283)
        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)
        XCTAssertEqual(start.source.trackURLs.count, 3)
        XCTAssertEqual(start.source.timeline.duration, 283, accuracy: 0.5)
        XCTAssertEqual(start.chapters.count, 3)

        let player = AudioPlayerService.shared
        player.load(source: start.source, title: book.title, seekTo: 150)
        try await waitUntil(timeout: 20) { !player.isSeekPending }
        player.play()
        try await waitUntil(timeout: 20) { player.currentTime > 156.5 }
        XCTAssertEqual(player.debugCurrentTrackIndex, 2, "Playback should have moved into the third file")
        player.pause()
        let position = player.currentTime

        await PlaybackSessionManager.shared.closeCurrentSession()

        let progress = try await serverProgress(for: book)
        XCTAssertEqual(progress?.currentTime ?? 0, position, accuracy: 2)
        XCTAssertGreaterThan(progress?.currentTime ?? 0, 95, "The server must see a position past the first file")
        XCTAssertEqual(progress?.isFinished, false)
    }

    @MainActor
    func testStreamingSingleFileControl() async throws {
        let book = try insertBook(kind: "m4b", duration: 150)
        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)
        XCTAssertEqual(start.source.trackURLs.count, 1)

        let player = AudioPlayerService.shared
        player.load(source: start.source, title: book.title, seekTo: 60)
        try await waitUntil(timeout: 20) { !player.isSeekPending }

        XCTAssertEqual(player.currentTime, 60, accuracy: 1)
        XCTAssertEqual(player.duration, 150, accuracy: 0.5)
    }

    @MainActor
    func testNewerServerPositionWinsWhenOpening() async throws {
        let book = try insertBook(kind: "m4a", duration: 215, position: 20)
        let token = try await token()
        try await AudiobookshelfAPI.shared.updateProgress(baseURL: server.normalizedURL, token: token, itemId: try XCTUnwrap(book.remoteItemId), currentTime: 100, duration: 215, isFinished: nil)

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(start.resumeSource, .server)
        XCTAssertEqual(start.resumePosition, 100, accuracy: 0.5)
        await PlaybackSessionManager.shared.closeCurrentSession()
    }

    // MARK: - Downloads

    @MainActor
    func testDownloadingMultiFileM4AStoresEveryFileAndPlaysAcrossThem() async throws {
        let book = try insertBook(kind: "m4a", duration: 215)
        let folderName = RemoteDownloadLayout.folderName(for: book.id)
        createdPaths.append(StorageManager.shared.remoteDownloadFolderURL(named: folderName))

        try await DownloadManager.shared.downloadBook(book, server: server, container: container)

        let saved = try fetch(book.id)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertEqual(saved.localCachePath, folderName)
        guard case .folder(let folderURL, let manifest) = RemoteDownloadLayout.resolve(
            localCachePath: folderName,
            cacheRoot: StorageManager.shared.remoteAudioCacheDirectoryURL,
            expectedBookID: book.id
        ) else { return XCTFail("Expected a valid download folder") }
        XCTAssertEqual(manifest.tracks.map(\.fileName), ["0001.m4a", "0002.m4a", "0003.m4a"])
        let serverItem = try await AudiobookshelfAPI.shared.fetchLibraryItem(
            baseURL: server.normalizedURL,
            token: try await token(),
            itemId: try XCTUnwrap(book.remoteItemId)
        )
        XCTAssertEqual(manifest.tracks.map(\.size), serverItem.media.tracks?.map { $0.metadata?.size.map { Int64($0) } })

        let source = try XCTUnwrap(manifest.playbackSource(folderURL: folderURL))
        let player = AudioPlayerService.shared
        player.load(source: source, title: book.title, seekTo: 120)
        try await waitUntil(timeout: 10) { !player.isSeekPending }
        XCTAssertEqual(player.debugCurrentTrackIndex, 2)
        XCTAssertEqual(player.currentTime, 120, accuracy: 0.5)
        player.seek(to: 10)
        try await waitUntil(timeout: 10) { !player.isSeekPending }
        XCTAssertEqual(player.debugCurrentTrackIndex, 0)
    }

    @MainActor
    func testTruncatedOlderDownloadIsReplacedAfterServerCheck() async throws {
        // Recreate what earlier versions stored: only the first MP3 file,
        // named .m4b, with the book marked downloaded.
        let book = try insertBook(kind: "mp3", duration: 283)
        let token = try await token()
        let item = try await AudiobookshelfAPI.shared.fetchLibraryItem(baseURL: server.normalizedURL, token: token, itemId: try XCTUnwrap(book.remoteItemId))
        let firstFile = try XCTUnwrap(item.media.tracks?.first?.contentUrl)
        let stream = try await AudiobookshelfAPI.shared.authenticatedStream(baseURL: server.normalizedURL, token: token, contentUrl: firstFile)
        let (data, _) = try await URLSession.shared.data(for: stream.makeRequest())
        let legacyName = "\(book.id.uuidString)_remote.m4b"
        let legacyURL = StorageManager.shared.remoteAudioCacheURL(for: legacyName)
        try data.write(to: legacyURL)
        createdPaths.append(legacyURL)
        book.isDownloaded = true
        book.localCachePath = legacyName
        try container.mainContext.save()

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container)

        let saved = try fetch(book.id)
        XCTAssertFalse(saved.isDownloaded)
        XCTAssertNil(saved.localCachePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    // MARK: - Helpers

    @MainActor
    private func insertBook(kind: String, duration: Double, position: Double = 0) throws -> Book {
        let itemID = try XCTUnwrap(environment.items[kind])
        let book = Book(title: "Integration \(kind)", duration: duration, lastPlaybackPosition: position, isRemote: true, remoteItemId: itemID, serverId: server.id)
        container.mainContext.insert(book)
        try container.mainContext.save()
        return book
    }

    private func token() async throws -> String {
        let baseURL = server.normalizedURL
        let stored = await AudiobookshelfAuth.shared.token(for: baseURL)
        return try XCTUnwrap(stored)
    }

    @MainActor
    private func fetch(_ id: UUID) throws -> Book {
        try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })).first)
    }

    private func serverProgress(for book: Book) async throws -> ServerProgressSnapshot? {
        let baseURL = server.normalizedURL
        let itemID = book.remoteItemId ?? ""
        let stored = await AudiobookshelfAuth.shared.token(for: baseURL)
        let token = try XCTUnwrap(stored)
        return try await AudiobookshelfAPI.shared.fetchProgressSnapshot(baseURL: baseURL, token: token, itemId: itemID)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
