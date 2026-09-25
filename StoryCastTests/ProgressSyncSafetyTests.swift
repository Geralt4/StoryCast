import SwiftData
import XCTest
@testable import StoryCast

/// Progress must only reach the server when something actually changed here,
/// and never carry data that makes the server discard newer or finished state.
nonisolated final class ProgressSyncSafetyTests: XCTestCase {
    private let serverURL = "https://abs-sync-safety-test.example.com"
    private let token = "sync-safety-token"
    private var containers: [ModelContainer] = []

    override func setUp() async throws {
        ABSStubURLProtocol.reset()
        try await AudiobookshelfAuth.shared.saveToken(token, for: serverURL)
        await MainActor.run {
            let api = ABSStubURLProtocol.makeAPI()
            PlaybackSessionManager.shared.debugOverrideAPI(api)
            ProgressBackupStore.shared.debugOverrideAPI(api)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            let manager = PlaybackSessionManager.shared
            manager.debugResetSession()
            manager.debugOverrideAPI(nil)
            manager.debugClearSeeking()
            ProgressBackupStore.shared.debugOverrideAPI(nil)
        }
        try? await AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        ABSStubURLProtocol.reset()
    }

    // MARK: - Change tracking

    @MainActor
    func testTrackerRecordsChangesAndSyncState() throws {
        let suite = "ProgressSyncSafetyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookID = UUID()
        let changedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let tracker = PlaybackProgressTracker(defaults: defaults)
        XCTAssertNil(tracker.state(for: bookID))
        tracker.recordChange(bookID: bookID, at: changedAt)
        XCTAssertTrue(tracker.isDirty(bookID: bookID))
        tracker.markSynced(bookID: bookID)

        let reloaded = PlaybackProgressTracker(defaults: defaults)
        XCTAssertEqual(reloaded.state(for: bookID), .init(changedAt: changedAt, isDirty: false))
    }

    // MARK: - Listened time

    @MainActor
    func testListenedTimeCountsWallClockAtFasterSpeeds() async throws {
        let manager = try await startSession()
        let start = Date()
        // At 1.5x the player publishes every 0.67 s of wall-clock time.
        for tick in 0...9 {
            manager.handlePlaybackTick(Double(tick) * 1.0, at: start.addingTimeInterval(Double(tick) * 0.667), isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        }

        XCTAssertEqual(manager.debugTotalTimeListened, 9 * 0.667, accuracy: 0.01)
    }

    @MainActor
    func testListenedTimeIgnoresPausesSeeksAndLongGaps() async throws {
        let manager = try await startSession()
        let start = Date()
        manager.handlePlaybackTick(0, at: start, isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        manager.handlePlaybackTick(1, at: start.addingTimeInterval(1), isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        // A seek in flight and a paused player earn nothing.
        manager.handlePlaybackTick(500, at: start.addingTimeInterval(2), isAudioAdvancing: true, isSeekPending: true, bookID: nil)
        manager.handlePlaybackTick(500, at: start.addingTimeInterval(3), isAudioAdvancing: false, isSeekPending: false, bookID: nil)
        // A long gap (a stall or suspension) is capped.
        manager.handlePlaybackTick(501, at: start.addingTimeInterval(60), isAudioAdvancing: true, isSeekPending: false, bookID: nil)

        XCTAssertEqual(manager.debugTotalTimeListened, 1 + 2, accuracy: 0.001)
    }

    @MainActor
    func testPlaybackTicksRecordPositionChange() async throws {
        let manager = try await startSession()
        let bookID = UUID()
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }
        let now = Date(timeIntervalSince1970: 1_700_000_500)

        manager.handlePlaybackTick(10, at: now, isAudioAdvancing: false, isSeekPending: false, bookID: bookID)
        XCTAssertNil(PlaybackProgressTracker.shared.lastChange(bookID: bookID))

        manager.handlePlaybackTick(11, at: now, isAudioAdvancing: true, isSeekPending: false, bookID: bookID)
        XCTAssertEqual(PlaybackProgressTracker.shared.lastChange(bookID: bookID), now)
    }

    // MARK: - Closing sessions

    @MainActor
    func testCloseWithoutListeningSendsEmptyBody() async throws {
        let manager = try await startSession()
        let sessionID = try ABSFixtures.playSession("abs-play-mp3-multi").id
        ABSStubURLProtocol.stub(path: "/api/session/\(sessionID)/close", body: Data("{}".utf8))

        await manager.closeCurrentSession()

        let close = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.url?.path == "/api/session/\(sessionID)/close" })
        XCTAssertEqual(close.httpBody, Data("{}".utf8))
    }

    @MainActor
    func testCloseAfterListeningReportsPosition() async throws {
        let manager = try await startSession()
        let sessionID = try ABSFixtures.playSession("abs-play-mp3-multi").id
        ABSStubURLProtocol.stub(path: "/api/session/\(sessionID)/close", body: Data("{}".utf8))
        let start = Date()
        manager.handlePlaybackTick(0, at: start, isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        manager.handlePlaybackTick(1, at: start.addingTimeInterval(1), isAudioAdvancing: true, isSeekPending: false, bookID: nil)

        await manager.closeCurrentSession()

        let close = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.url?.path == "/api/session/\(sessionID)/close" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(close.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["currentTime"])
        XCTAssertEqual(try XCTUnwrap(body["timeListened"] as? Double), 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(body["duration"] as? Double), 283, accuracy: 0.01)
    }

    @MainActor
    func testFailedCloseBacksUpWithTimeOfLastChange() async throws {
        let (manager, book) = try await startSessionReturningBook()
        let itemID = try XCTUnwrap(book.remoteItemId)
        defer {
            ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID)
            PlaybackProgressTracker.shared.clear(bookID: book.id)
        }
        let changedAt = Date(timeIntervalSince1970: 1_700_001_000)
        PlaybackProgressTracker.shared.recordChange(bookID: book.id, at: changedAt)
        let start = Date()
        manager.handlePlaybackTick(0, at: start, isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        manager.handlePlaybackTick(1, at: start.addingTimeInterval(1), isAudioAdvancing: true, isSeekPending: false, bookID: nil)
        // No stub for /close, so the request fails and the progress is backed up.

        await manager.closeCurrentSession()

        XCTAssertEqual(ProgressBackupStore.shared.debugBackupTimestamp(serverURL: serverURL, itemId: itemID), changedAt.timeIntervalSince1970)
    }

    // MARK: - Recovery

    @MainActor
    func testRecoveryOmitsIsFinishedForUnfinishedBook() async throws {
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID = "item-recovery"
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", method: "GET", status: 404, body: Data())
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", method: "PATCH", body: Data("{}".utf8))
        ProgressBackupStore.shared.debugBackup(serverURL: serverURL, itemId: itemID, currentTime: 120, timeListened: 30, duration: 283)
        defer { ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID) }

        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemID)

        let patch = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertNil(body["isFinished"])
        XCTAssertEqual(body["currentTime"] as? Double, 120)
        XCTAssertFalse(ProgressBackupStore.shared.debugHasPending(serverURL: serverURL, itemId: itemID))
    }

    @MainActor
    func testRecoveryMarksFinishedBookFinished() async throws {
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID = "item-recovery-finished"
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", method: "GET", status: 404, body: Data())
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", method: "PATCH", body: Data("{}".utf8))
        ProgressBackupStore.shared.debugBackup(serverURL: serverURL, itemId: itemID, currentTime: 280, timeListened: 30, duration: 283)
        defer { ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID) }

        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemID)

        let patch = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(body["isFinished"] as? Bool, true)
    }

    // MARK: - Helpers

    @MainActor
    private func startSession() async throws -> PlaybackSessionManager {
        try await startSessionReturningBook().0
    }

    @MainActor
    private func startSessionReturningBook() async throws -> (PlaybackSessionManager, Book) {
        let session = try ABSFixtures.playSession("abs-play-mp3-multi")
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: try ABSFixtures.data("abs-play-mp3-multi"))
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        containers.append(container)
        let context = ModelContext(container)
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let book = Book(title: "Sync Safety", duration: 283, isRemote: true, remoteItemId: session.libraryItemId, serverId: server.id)
        context.insert(server)
        context.insert(book)
        try context.save()

        let manager = PlaybackSessionManager.shared
        _ = try await manager.startSession(for: book, server: server)
        return (manager, book)
    }
}
