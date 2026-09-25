import AVFoundation
import Combine
import XCTest
@testable import StoryCast

/// Drives the real AVQueuePlayer-based engine with short generated WAV files.
nonisolated final class AudioPlayerQueueTests: XCTestCase {
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

    // MARK: - Loading

    @MainActor
    func testLoadPublishesWholeBookDurationAndIdentitySynchronously() async throws {
        let source = try makeSource(durations: [1.0, 0.5, 0.8])
        let player = AudioPlayerService.shared

        player.load(source: source, title: "Three Files", seekTo: 0)

        XCTAssertEqual(player.duration, 2.3, accuracy: 0.001)
        XCTAssertEqual(player.currentBookID, source.bookID)
        XCTAssertEqual(player.currentURL, source.identityURL)
        XCTAssertEqual(player.debugQueuedTrackIndices, [0, 1])
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testResumeIntoLaterFileIsNotClampedByPreviousBook() async throws {
        let player = AudioPlayerService.shared
        let short = try makeAudioFile(duration: 0.1)
        player.loadAudio(url: short, title: "Short", duration: 0.1, seekTo: 0)
        try await waitUntil { !player.debugIsSeekPending }

        let source = try makeSource(durations: [1.0, 0.5, 0.8])
        player.load(source: source, title: "Three Files", seekTo: 1.7)

        XCTAssertEqual(player.currentTime, 1.7, accuracy: 0.001)
        try await waitUntil { !player.debugIsSeekPending }
        XCTAssertEqual(player.debugCurrentTrackIndex, 2)
        XCTAssertEqual(player.currentTime, 1.7, accuracy: 0.05)
    }

    // MARK: - Seeking

    @MainActor
    func testSeekWithinFileDoesNotRebuildQueue() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 0)
        let rebuilds = player.debugQueueRebuildCount

        player.seek(to: 0.4)
        try await waitUntil { !player.debugIsSeekPending }

        XCTAssertEqual(player.debugQueueRebuildCount, rebuilds)
        XCTAssertEqual(player.debugCurrentTrackIndex, 0)
        XCTAssertEqual(player.currentTime, 0.4, accuracy: 0.05)
    }

    @MainActor
    func testSeekIntoPreloadedNextFileAdvancesWithoutRebuild() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 0)
        let rebuilds = player.debugQueueRebuildCount

        player.seek(to: 1.2)
        try await waitUntil { !player.debugIsSeekPending }

        XCTAssertEqual(player.debugQueueRebuildCount, rebuilds)
        XCTAssertEqual(player.debugCurrentTrackIndex, 1)
        XCTAssertEqual(player.currentTime, 1.2, accuracy: 0.05)
        try await waitUntil { player.debugQueuedTrackIndices == [1, 2] }
    }

    @MainActor
    func testBackwardSeekAcrossFilesRebuildsFromTarget() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 2.0)
        XCTAssertEqual(player.debugQueuedTrackIndices, [2])
        let rebuilds = player.debugQueueRebuildCount

        player.seek(to: 0.2)
        try await waitUntil { !player.debugIsSeekPending }

        XCTAssertEqual(player.debugQueueRebuildCount, rebuilds + 1)
        XCTAssertEqual(player.debugQueuedTrackIndices, [0, 1])
        XCTAssertEqual(player.currentTime, 0.2, accuracy: 0.05)
    }

    @MainActor
    func testForwardSeekPastPreloadedFileRebuilds() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 0)
        let rebuilds = player.debugQueueRebuildCount

        player.seek(to: 2.0)
        try await waitUntil { !player.debugIsSeekPending }

        XCTAssertEqual(player.debugQueueRebuildCount, rebuilds + 1)
        XCTAssertEqual(player.debugQueuedTrackIndices, [2])
        XCTAssertEqual(player.currentTime, 2.0, accuracy: 0.05)
    }

    @MainActor
    func testSeekBeyondEndClampsToBookEnd() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5], at: 0)

        player.seek(to: 100)
        try await waitUntil { !player.debugIsSeekPending }

        XCTAssertEqual(player.debugCurrentTrackIndex, 1)
        XCTAssertLessThanOrEqual(player.currentTime, 1.5)
        XCTAssertGreaterThan(player.currentTime, 1.0)
    }

    // MARK: - Time and end of book

    @MainActor
    func testPeriodicTimeUsesCurrentFilesOwnTime() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 1.2)

        player.debugPublishPlaybackTime()

        XCTAssertEqual(player.debugCurrentTrackIndex, 1)
        XCTAssertEqual(player.currentTime, 1.2, accuracy: 0.05)
    }

    @MainActor
    func testEndOfMiddleFileIsNotEndOfBook() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 0)

        player.debugHandleItemReachedEnd(player.debugCurrentItem)

        XCTAssertFalse(player.playbackDidReachEnd)
    }

    @MainActor
    func testEndOfLastFileReportsEndOfBook() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 2.0)

        player.debugHandleItemReachedEnd(player.debugCurrentItem)

        XCTAssertTrue(player.playbackDidReachEnd)
        XCTAssertEqual(player.currentTime, 2.3, accuracy: 0.001)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testNotificationsFromReplacedQueueAreIgnored() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 2.0)
        let staleLastItem = player.debugCurrentItem

        player.seek(to: 0.1)
        try await waitUntil { !player.debugIsSeekPending }
        player.debugHandleItemReachedEnd(staleLastItem)

        XCTAssertFalse(player.playbackDidReachEnd)
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.05)
    }

    // MARK: - Play state

    @MainActor
    func testFailureOfCurrentFilePausesAndPlayRebuildsQueue() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5, 0.8], at: 1.2)

        player.debugSimulateCurrentItemFailure(message: "Network lost")

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.lastPlaybackError, "Network lost")
        XCTAssertTrue(player.debugQueuedTrackIndices.isEmpty)
        XCTAssertEqual(player.currentTime, 1.2, accuracy: 0.05)

        player.play()
        XCTAssertEqual(player.debugQueuedTrackIndices, [1, 2])
        XCTAssertNil(player.lastPlaybackError)
        player.pause()
    }

    @MainActor
    func testToggleRightAfterPlayPauses() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5], at: 0)

        player.play()
        XCTAssertTrue(player.isPlaying)
        player.togglePlayPause()

        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testPlaybackRateIsTheQueueDefaultRate() async throws {
        let player = try await loadSettled(durations: [1.0, 0.5], at: 0)
        let originalRate = player.playbackRate
        defer { player.setPlaybackRate(originalRate) }

        player.setPlaybackRate(1.5)

        XCTAssertEqual(player.debugDefaultRate, 1.5)
    }

    @MainActor
    func testSingleFileWrapperRefinesGuessedDuration() async throws {
        let player = AudioPlayerService.shared
        let url = try makeAudioFile(duration: 0.5)

        player.loadAudio(url: url, title: "Single", duration: 10, seekTo: 0)
        XCTAssertEqual(player.duration, 10)

        try await waitUntil { abs(player.duration - 0.5) < 0.05 }
        XCTAssertNil(player.currentBookID)
        XCTAssertEqual(player.currentURL, url)
    }

    @MainActor
    func testSingleFileResumeIsNotClampedByPlaceholderDuration() async throws {
        let player = AudioPlayerService.shared
        let url = try makeAudioFile(duration: 1.0)

        player.loadAudio(url: url, title: "Placeholder", duration: 0.1, seekTo: 0.6)

        XCTAssertEqual(player.currentTime, 0.6, accuracy: 0.001)
        try await waitUntil { !player.debugIsSeekPending }
        XCTAssertEqual(player.currentTime, 0.6, accuracy: 0.05)
    }

    @MainActor
    func testRealPlaybackCrossesFilesAndEndsOnce() async throws {
        let player = AudioPlayerService.shared
        let source = try makeSource(durations: [0.6, 0.6, 0.6])
        player.load(source: source, title: "Real Playback", seekTo: 0)
        try await waitUntil { !player.debugIsSeekPending }

        var endCount = 0
        var sawAudio = false
        let cancellables = [
            player.$playbackDidReachEnd.sink { if $0 { endCount += 1 } },
            player.$isAudioAdvancing.sink { if $0 { sawAudio = true } }
        ]
        defer { cancellables.forEach { $0.cancel() } }

        player.play()
        let started = Date()
        while !sawAudio && Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try XCTSkipUnless(sawAudio, "Audio playback is unavailable in this environment")

        try await waitUntil(timeout: 10) { endCount > 0 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(player.currentTime, 1.8, accuracy: 0.001)
    }

    // MARK: - Helpers

    @MainActor
    private func loadSettled(durations: [Double], at time: Double) async throws -> AudioPlayerService {
        let player = AudioPlayerService.shared
        player.load(source: try makeSource(durations: durations), title: "Test Book", seekTo: time)
        try await waitUntil { !player.debugIsSeekPending }
        return player
    }

    private func makeSource(durations: [Double]) throws -> PlaybackSource {
        let urls = try durations.map { try makeAudioFile(duration: $0) }
        let timeline = try XCTUnwrap(PlaybackTimeline(durations: durations))
        return try XCTUnwrap(PlaybackSource(
            bookID: UUID(),
            identityURL: urls[0].deletingLastPathComponent(),
            trackURLs: urls,
            timeline: timeline
        ))
    }

    private func makeAudioFile(duration: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPlayerQueueTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let url = directory.appendingPathComponent("track.wav")
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * duration)) else {
            throw NSError(domain: "AudioPlayerQueueTests", code: 1)
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
