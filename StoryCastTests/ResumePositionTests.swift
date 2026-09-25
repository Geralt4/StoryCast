import AVFoundation
import SwiftData
import XCTest
@testable import StoryCast

/// Resuming from the newest position, and syncing downloaded books.
nonisolated final class ResumePositionTests: XCTestCase {
    private let serverURL = "https://abs-resume-test.example.com"
    private var containers: [ModelContainer] = []
    private var tempDirectories: [URL] = []

    override func setUp() async throws {
        ABSStubURLProtocol.reset()
        try await AudiobookshelfAuth.shared.saveToken("resume-token", for: serverURL)
        await MainActor.run {
            let api = ABSStubURLProtocol.makeAPI()
            PlaybackSessionManager.shared.debugOverrideAPI(api)
            ProgressBackupStore.shared.debugOverrideAPI(api)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PlaybackSessionManager.shared.debugResetSession()
            PlaybackSessionManager.shared.debugOverrideAPI(nil)
            PlaybackSessionManager.shared.debugClearSeeking()
            ProgressBackupStore.shared.debugOverrideAPI(nil)
            AudioPlayerService.shared.unload()
        }
        try? await AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        ABSStubURLProtocol.reset()
        for directory in tempDirectories { try? FileManager.default.removeItem(at: directory) }
        tempDirectories.removeAll()
    }

    // MARK: - Resolver

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func server(_ position: Double, updated: Date?, offset: TimeInterval? = 0, finished: Bool = false) -> ServerProgressSnapshot {
        ServerProgressSnapshot(currentTime: position, duration: 283, isFinished: finished, lastUpdate: updated, serverClockOffset: offset)
    }

    func testNoServerProgressKeepsLocal() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: nil, timelineDuration: 283)
        XCTAssertEqual(decision, .init(position: 50, source: .local))
    }

    func testNothingUnsyncedHereTakesServer() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: false), server: server(200, updated: now.addingTimeInterval(-3600)), timelineDuration: 283)
        XCTAssertEqual(decision, .init(position: 200, source: .server))
    }

    func testNeverPlayedHereTakesServer() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 0, changedAt: nil, isDirty: false), server: server(200, updated: now), timelineDuration: 283)
        XCTAssertEqual(decision.source, .server)
    }

    func testNewerServerProgressWinsOverOlderUnsyncedChange() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(60)), timelineDuration: 283)
        XCTAssertEqual(decision, .init(position: 200, source: .server))
    }

    func testNewerUnsyncedChangeHereWins() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(-60)), timelineDuration: 283)
        XCTAssertEqual(decision, .init(position: 50, source: .local))
    }

    func testTooCloseToCallKeepsUnsyncedChange() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(5)), timelineDuration: 283)
        XCTAssertEqual(decision.source, .local)
    }

    func testServerClockOffsetIsCorrected() {
        // The server's clock runs 120 s ahead: its update 100 s "later" was
        // really 20 s earlier than the change here.
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(100), offset: 120), timelineDuration: 283)
        XCTAssertEqual(decision.source, .local)
    }

    func testWithoutDateHeaderAWideToleranceApplies() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(200), offset: nil), timelineDuration: 283)
        XCTAssertEqual(decision.source, .local)
        let later = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: now.addingTimeInterval(400), offset: nil), timelineDuration: 283)
        XCTAssertEqual(later.source, .server)
    }

    func testUntimestampedServerPositionDoesNotBeatUnsyncedChange() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: now, isDirty: true), server: server(200, updated: nil, offset: nil), timelineDuration: 283)
        XCTAssertEqual(decision.source, .local)
    }

    func testFinishedOnServerRestartsFromBeginning() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: nil, isDirty: false), server: server(283, updated: now, finished: true), timelineDuration: 283)
        XCTAssertEqual(decision, .init(position: 0, source: .server))
    }

    func testPositionIsClampedToPlayableLength() {
        let decision = ResumePositionResolver.resolve(local: .init(position: 50, changedAt: nil, isDirty: false), server: server(900, updated: now), timelineDuration: 283)
        XCTAssertEqual(decision.position, 283)
    }

    func testHTTPDateParsing() {
        let date = ResumePositionResolver.parseHTTPDate("Fri, 25 Sep 2026 10:18:12 GMT")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_790_331_492)
        XCTAssertNil(ResumePositionResolver.parseHTTPDate("yesterday"))
    }

    // MARK: - Snapshot from the server

    @MainActor
    func testSnapshotReadsRecordedProgressAndClockOffset() async throws {
        let itemID = "item-snapshot"
        let headers = try XCTUnwrap(JSONSerialization.jsonObject(with: ABSFixtures.data("abs-progress-mp3.headers")) as? [String: Any])
        let date = try XCTUnwrap((headers["headers"] as? [String: String])?["Date"] ?? headers["Date"] as? String)
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", body: try ABSFixtures.data("abs-progress-mp3"), headers: ["Content-Type": "application/json", "Date": date])

        let fetched = try await ABSStubURLProtocol.makeAPI().fetchProgressSnapshot(baseURL: serverURL, token: "t", itemId: itemID)
        let snapshot = try XCTUnwrap(fetched)

        XCTAssertEqual(snapshot.currentTime, 130)
        XCTAssertNotNil(snapshot.lastUpdate)
        XCTAssertNotNil(snapshot.serverClockOffset)
        XCTAssertFalse(snapshot.isFinished)
    }

    // MARK: - Starting a stream

    @MainActor
    func testStreamResumesFromNewerServerProgress() async throws {
        let (book, server) = try makeBook(position: 20)
        PlaybackProgressTracker.shared.recordChange(bookID: book.id, at: Date().addingTimeInterval(-3600))
        PlaybackProgressTracker.shared.markSynced(bookID: book.id)
        defer { PlaybackProgressTracker.shared.clear(bookID: book.id) }
        stubProgress(itemID: try XCTUnwrap(book.remoteItemId), position: 150, updatedAgo: 60)

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(start.resumeSource, .server)
        XCTAssertEqual(start.resumePosition, 150)
    }

    @MainActor
    func testStreamKeepsNewerUnsyncedPositionHere() async throws {
        let (book, server) = try makeBook(position: 20)
        PlaybackProgressTracker.shared.recordChange(bookID: book.id, at: Date())
        defer { PlaybackProgressTracker.shared.clear(bookID: book.id) }
        stubProgress(itemID: try XCTUnwrap(book.remoteItemId), position: 150, updatedAgo: 3600)

        let start = try await PlaybackSessionManager.shared.startSession(for: book, server: server)

        XCTAssertEqual(start.resumeSource, .local)
        XCTAssertEqual(start.resumePosition, 20)
    }

    // MARK: - Recovery

    @MainActor
    func testOlderBackupIsDroppedInsteadOfOverwritingServer() async throws {
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID = "item-old-backup"
        ProgressBackupStore.shared.backup(serverURL: serverURL, itemId: itemID, currentTime: 40, timeListened: 10, duration: 283, changedAt: Date().addingTimeInterval(-3600))
        defer { ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID) }
        stubProgress(itemID: itemID, position: 200, updatedAgo: 60)

        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemID)

        XCTAssertFalse(ABSStubURLProtocol.requests.contains { $0.httpMethod == "PATCH" })
        XCTAssertFalse(ProgressBackupStore.shared.debugHasPending(serverURL: serverURL, itemId: itemID))
    }

    @MainActor
    func testNewerBackupIsSent() async throws {
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID = "item-new-backup"
        ProgressBackupStore.shared.backup(serverURL: serverURL, itemId: itemID, currentTime: 240, timeListened: 10, duration: 283, changedAt: Date())
        defer { ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID) }
        stubProgress(itemID: itemID, position: 200, updatedAgo: 3600)

        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemID)

        let patch = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(body["currentTime"] as? Double, 240)
    }

    @MainActor
    func testRecoveryKeepsBackupWhenServerCantBeReached() async throws {
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID = "item-offline-backup"
        ProgressBackupStore.shared.backup(serverURL: serverURL, itemId: itemID, currentTime: 240, timeListened: 10, duration: 283, changedAt: Date())
        defer { ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID) }

        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemID)

        XCTAssertTrue(ProgressBackupStore.shared.debugHasPending(serverURL: serverURL, itemId: itemID))
    }

    // MARK: - Downloaded books

    @MainActor
    func testDownloadedBookReportsChangedPosition() async throws {
        let itemID = "item-downloaded"
        let bookID = try await loadDownloadedBook(itemID: itemID, seekTo: 0.5)
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", method: "PATCH", body: Data("{}".utf8))
        PlaybackProgressTracker.shared.recordChange(bookID: bookID)

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true)

        let patch = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(body["currentTime"] as? Double), 0.5, accuracy: 0.05)
        XCTAssertNil(body["isFinished"])
        XCTAssertFalse(PlaybackProgressTracker.shared.isDirty(bookID: bookID))
    }

    @MainActor
    func testDownloadedBookWithoutChangesReportsNothing() async throws {
        let bookID = try await loadDownloadedBook(itemID: "item-unchanged", seekTo: 0.5)
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true)

        XCTAssertTrue(ABSStubURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testDownloadedBookReportIsThrottled() async throws {
        let itemID = "item-throttle"
        let bookID = try await loadDownloadedBook(itemID: itemID, seekTo: 0.5)
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", body: Data("{}".utf8))
        PlaybackProgressTracker.shared.recordChange(bookID: bookID)
        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true)
        PlaybackProgressTracker.shared.recordChange(bookID: bookID)

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: false)

        XCTAssertEqual(ABSStubURLProtocol.requests.filter { $0.httpMethod == "PATCH" }.count, 1)
    }

    @MainActor
    func testFailedReportBacksUpWithChangeTime() async throws {
        let itemID = "item-report-fails"
        let bookID = try await loadDownloadedBook(itemID: itemID, seekTo: 0.5)
        defer {
            PlaybackProgressTracker.shared.clear(bookID: bookID)
            ProgressBackupStore.shared.debugClear(serverURL: serverURL, itemId: itemID)
        }
        let changedAt = Date(timeIntervalSince1970: 1_790_000_000)
        PlaybackProgressTracker.shared.recordChange(bookID: bookID, at: changedAt)

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true)

        XCTAssertEqual(ProgressBackupStore.shared.debugBackupTimestamp(serverURL: serverURL, itemId: itemID), changedAt.timeIntervalSince1970)
        XCTAssertTrue(PlaybackProgressTracker.shared.isDirty(bookID: bookID))
    }

    @MainActor
    func testEndOfBookIsReportedFinished() async throws {
        let itemID = "item-finished"
        let bookID = try await loadDownloadedBook(itemID: itemID, seekTo: 0.9)
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", body: Data("{}".utf8))

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true, isFinished: true)

        let patch = try XCTUnwrap(ABSStubURLProtocol.requests.last { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(body["isFinished"] as? Bool, true)
    }

    @MainActor
    func testPartialOlderDownloadNeverReports() async throws {
        let itemID = "item-partial"
        let bookID = try await loadDownloadedBook(itemID: itemID, seekTo: 0.5, coversWholeBook: false)
        defer { PlaybackProgressTracker.shared.clear(bookID: bookID) }
        PlaybackProgressTracker.shared.recordChange(bookID: bookID)

        await PlaybackSessionManager.shared.reportSessionlessProgress(force: true, isFinished: true)

        XCTAssertTrue(ABSStubURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testLoadingAnotherBookStopsReporting() async throws {
        _ = try await loadDownloadedBook(itemID: "item-first", seekTo: 0)
        XCTAssertTrue(PlaybackSessionManager.shared.debugHasSessionlessTarget)

        AudioPlayerService.shared.loadAudio(url: try makeAudioFile(), title: "Other", duration: 1, seekTo: 0)

        XCTAssertFalse(PlaybackSessionManager.shared.debugHasSessionlessTarget)
    }

    // MARK: - Helpers

    private func stubProgress(itemID: String, position: Double, updatedAgo: TimeInterval) {
        let lastUpdate = (Date().timeIntervalSince1970 - updatedAgo) * 1000
        let body = """
        {"id":"p","libraryItemId":"\(itemID)","duration":283,"progress":0.5,"currentTime":\(position),"isFinished":false,"lastUpdate":\(lastUpdate)}
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        ABSStubURLProtocol.stub(path: "/api/me/progress/\(itemID)", body: Data(body.utf8), headers: ["Content-Type": "application/json", "Date": formatter.string(from: Date())])
    }

    @MainActor
    private func makeBook(position: Double) throws -> (Book, ABSServer) {
        let session = try ABSFixtures.playSession("abs-play-mp3-multi")
        ABSStubURLProtocol.stub(path: "/api/items/\(session.libraryItemId)/play", body: try ABSFixtures.data("abs-play-mp3-multi"))
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let book = Book(title: "Resume", duration: 283, lastPlaybackPosition: position, isRemote: true, remoteItemId: session.libraryItemId, serverId: server.id)
        container.mainContext.insert(server)
        container.mainContext.insert(book)
        try container.mainContext.save()
        return (book, server)
    }

    @MainActor
    private func loadDownloadedBook(itemID: String, seekTo time: Double, coversWholeBook: Bool = true) async throws -> UUID {
        let bookID = UUID()
        let url = try makeAudioFile()
        let player = AudioPlayerService.shared
        player.load(source: .singleFile(url: url, duration: 1, bookID: bookID, coversWholeBook: coversWholeBook), title: "Downloaded", seekTo: time)
        PlaybackSessionManager.shared.beginSessionlessReporting(bookID: bookID, itemId: itemID, serverURL: serverURL, duration: 1)
        let deadline = Date().addingTimeInterval(5)
        while player.isSeekPending, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return bookID
    }

    private func makeAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResumePositionTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent("book.wav")
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)) else {
            throw NSError(domain: "ResumePositionTests", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}
