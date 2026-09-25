import AVFoundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class PlaybackPositionSaverTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() async throws {
        await MainActor.run {
            AudioPlayerService.shared.unload()
            PlaybackSessionManager.shared.debugClearSeeking()
        }
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    @MainActor
    func testSavesByBookIDForMultiFileSource() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let book = Book(title: "Remote", duration: 2, isRemote: true, remoteItemId: "item-1", isDownloaded: true)
        context.insert(book)
        try context.save()

        try await load(bookID: book.id, trackNames: ["0001.wav", "0002.wav"], seekTo: 1.4)
        PlaybackPositionSaver.saveCurrentPosition(container: container)

        let saved = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Book>()).first)
        XCTAssertEqual(saved.lastPlaybackPosition, 1.4, accuracy: 0.05)
    }

    @MainActor
    func testDoesNotWriteIntoLocalBookNamedLikeTrackFile() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let local = Book(title: "Local", localFileName: "0001.wav", duration: 5, lastPlaybackPosition: 3, isImported: true)
        let remote = Book(title: "Remote", duration: 2, isRemote: true, remoteItemId: "item-1", isDownloaded: true)
        context.insert(local)
        context.insert(remote)
        try context.save()

        try await load(bookID: remote.id, trackNames: ["0001.wav", "0002.wav"], seekTo: 0.5)
        PlaybackPositionSaver.saveCurrentPosition(container: container)

        let books = try ModelContext(container).fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.first { $0.id == local.id }?.lastPlaybackPosition, 3)
        XCTAssertEqual(try XCTUnwrap(books.first { $0.id == remote.id }).lastPlaybackPosition, 0.5, accuracy: 0.05)
    }

    @MainActor
    func testLegacyLoadWithoutBookIDStillMatchesByFileName() async throws {
        let container = try makeContainer()
        let url = try makeAudioFile(named: "Legacy Book.wav", duration: 1)
        let context = ModelContext(container)
        let book = Book(title: "Legacy", localFileName: "Legacy Book.wav", duration: 1, isImported: true)
        context.insert(book)
        try context.save()

        let player = AudioPlayerService.shared
        player.loadAudio(url: url, title: "Legacy", duration: 1, seekTo: 0.3)
        try await waitUntil { !player.debugIsSeekPending }
        PlaybackPositionSaver.saveCurrentPosition(container: container)

        let saved = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Book>()).first)
        XCTAssertEqual(saved.lastPlaybackPosition, 0.3, accuracy: 0.05)
    }

    // MARK: - Helpers

    @MainActor
    private func load(bookID: UUID, trackNames: [String], seekTo time: Double) async throws {
        let urls = try trackNames.map { try makeAudioFile(named: $0, duration: 1) }
        let timeline = try XCTUnwrap(PlaybackTimeline(durations: urls.map { _ in 1 }))
        let source = try XCTUnwrap(PlaybackSource(
            bookID: bookID,
            identityURL: urls[0].deletingLastPathComponent(),
            trackURLs: urls,
            timeline: timeline
        ))
        let player = AudioPlayerService.shared
        player.load(source: source, title: "Test", seekTo: time)
        try await waitUntil { !player.debugIsSeekPending }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeAudioFile(named name: String, duration: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackPositionSaverTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
            throw NSError(domain: "PlaybackPositionSaverTests", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
