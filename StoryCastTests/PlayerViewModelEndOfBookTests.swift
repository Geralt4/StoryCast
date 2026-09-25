import AVFoundation
import XCTest
@testable import StoryCast

nonisolated final class PlayerViewModelEndOfBookTests: XCTestCase {
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
    func testWholeBookSourceShorterThanBookStillMarksBookFinished() throws {
        // The server's item duration can include files it excludes from playback.
        let book = Book(title: "Excluded Extras", duration: 3.0, isRemote: true)
        try load(book: book, durations: [1.0, 0.5, 0.8])

        XCTAssertEqual(PlayerViewModel(book: book).endOfPlaybackPosition(), 3.0, accuracy: 0.001)
    }

    @MainActor
    func testPlaceholderBookDurationUsesTimelineEnd() throws {
        let book = Book(title: "Placeholder", duration: 1.0, isRemote: true)
        try load(book: book, durations: [1.0, 0.5, 0.8])

        XCTAssertEqual(PlayerViewModel(book: book).endOfPlaybackPosition(), 2.3, accuracy: 0.001)
    }

    @MainActor
    func testSafeDurationUsesPlayerTimelineWhileLoaded() throws {
        let book = Book(title: "Loaded", duration: 1.0, isRemote: true)
        let viewModel = PlayerViewModel(book: book)
        XCTAssertEqual(viewModel.safeDuration, 1.0)

        try load(book: book, durations: [1.0, 0.5, 0.8])

        XCTAssertEqual(viewModel.safeDuration, 2.3, accuracy: 0.001)
    }

    @MainActor
    private func load(book: Book, durations: [Double]) throws {
        let urls = try durations.map { try makeAudioFile(duration: $0) }
        let source = try XCTUnwrap(PlaybackSource(
            bookID: book.id,
            identityURL: urls[0].deletingLastPathComponent(),
            trackURLs: urls,
            timeline: try XCTUnwrap(PlaybackTimeline(durations: durations))
        ))
        AudioPlayerService.shared.load(source: source, title: book.title, seekTo: 0)
    }

    private func makeAudioFile(duration: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerViewModelEndOfBookTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent("track.wav")
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
            throw NSError(domain: "PlayerViewModelEndOfBookTests", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}
