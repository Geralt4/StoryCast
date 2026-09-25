import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class PlaybackSessionManagerMultiTrackTests: XCTestCase {
    private let serverURL = "https://abs-multitrack-test.example.com"
    private let token = "multitrack-test-token"

    override func setUp() async throws {
        ABSStubURLProtocol.reset()
        try await AudiobookshelfAuth.shared.saveToken(token, for: serverURL)
        await MainActor.run {
            PlaybackSessionManager.shared.debugOverrideAPI(ABSStubURLProtocol.makeAPI())
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            let manager = PlaybackSessionManager.shared
            manager.debugResetSession()
            manager.debugOverrideAPI(nil)
            manager.debugClearSeeking()
        }
        try? await AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        ABSStubURLProtocol.reset()
    }

    @MainActor
    func testStartSessionBuildsSourceFromEveryFileWithBearerHeader() async throws {
        let (book, server, session) = try makeBook(fixture: "abs-play-mp3-multi", position: 120)
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: try ABSFixtures.data("abs-play-mp3-multi"))

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(start.source.trackURLs.count, 3)
        XCTAssertEqual(
            start.source.trackURLs.map(\.absoluteString),
            session.audioTracks.map { "\(serverURL)/api/items/\(session.libraryItemId)/file/\($0.ino!)" }
        )
        XCTAssertEqual(start.source.httpHeaders, ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(start.source.timeline.duration, 283, accuracy: 0.001)
        XCTAssertEqual(start.source.bookID, book.id)
        XCTAssertFalse(start.source.isLocal)
        XCTAssertEqual(start.sessionDuration, 283, accuracy: 0.001)
        XCTAssertEqual(start.resumePosition, 120)
        XCTAssertEqual(start.chapters.count, 3)
        XCTAssertEqual(PlaybackSessionManager.shared.debugSessionDuration, 283, accuracy: 0.001)
        XCTAssertEqual(PlaybackSessionManager.shared.debugActiveTitle, book.title)
        XCTAssertTrue(PlaybackSessionManager.shared.isCurrentSession(for: book))
    }

    @MainActor
    func testResumePositionIsClampedToPlayableLength() async throws {
        let (book, server, session) = try makeBook(fixture: "abs-play-m4a-multi", position: 10_000)
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: try ABSFixtures.data("abs-play-m4a-multi"))

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(start.resumePosition, 215, accuracy: 0.001)
    }

    @MainActor
    func testSessionFailsWhenAnyFileURLFailsValidation() async throws {
        let (book, server, session) = try makeBook(fixture: "abs-play-mp3-multi", position: 0)
        let body = try modifiedFixture("abs-play-mp3-multi") { tracks in
            tracks[1]["contentUrl"] = "https://evil.example.com/api/items/x/file/1"
        }
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: body)

        do {
            _ = try await PlaybackSessionManager.shared.startSession(for: book, server: server)
            XCTFail("Expected the session to fail")
        } catch {
            XCTAssertFalse(PlaybackSessionManager.shared.isCurrentSession(for: book))
        }
    }

    @MainActor
    func testMissingContentUrlFallsBackToFileIdentifierPath() async throws {
        let (book, server, session) = try makeBook(fixture: "abs-play-mp3-multi", position: 0)
        let body = try modifiedFixture("abs-play-mp3-multi") { tracks in
            for index in tracks.indices { tracks[index]["contentUrl"] = nil }
        }
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: body)

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(
            start.source.trackURLs.map(\.path),
            session.audioTracks.map { "/api/items/\(session.libraryItemId)/file/\($0.ino!)" }
        )
    }

    @MainActor
    func testMissingFileDurationFailsSession() async throws {
        let (book, server, session) = try makeBook(fixture: "abs-play-mp3-multi", position: 0)
        let body = try modifiedFixture("abs-play-mp3-multi") { tracks in
            tracks[2]["duration"] = nil
        }
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: body)

        do {
            _ = try await PlaybackSessionManager.shared.startSession(for: book, server: server)
            XCTFail("Expected the session to fail")
        } catch APIError.invalidResponse {
            // Expected
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeBook(fixture: String, position: Double) throws -> (Book, ABSServer, ABSPlaybackSession) {
        let session = try ABSFixtures.playSession(fixture)
        // No progress on the server, so the book resumes from this device's position.
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(session.libraryItemId)", status: 404, body: Data())
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let book = Book(
            title: "Multi-file Test",
            duration: session.duration ?? 0,
            lastPlaybackPosition: position,
            isRemote: true,
            remoteItemId: session.libraryItemId,
            serverId: server.id
        )
        context.insert(server)
        context.insert(book)
        try context.save()
        retainedContainers.append(container)
        return (book, server, session)
    }

    private var retainedContainers: [ModelContainer] = []

    private func modifiedFixture(_ name: String, change: (inout [[String: Any]]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ABSFixtures.data(name)) as? [String: Any])
        var tracks = try XCTUnwrap(json["audioTracks"] as? [[String: Any]])
        change(&tracks)
        json["audioTracks"] = tracks
        return try JSONSerialization.data(withJSONObject: json)
    }
}
