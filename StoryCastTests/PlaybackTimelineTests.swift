import XCTest
@testable import StoryCast

nonisolated final class PlaybackTimelineTests: XCTestCase {
    private func makeTimeline(_ durations: [Double]) throws -> PlaybackTimeline {
        try XCTUnwrap(PlaybackTimeline(durations: durations))
    }

    func testCumulativeOffsets() throws {
        let timeline = try makeTimeline([95, 61, 127])
        XCTAssertEqual(timeline.segments.map(\.startOffset), [0, 95, 156])
        XCTAssertEqual(timeline.duration, 283)
    }

    func testInitRejectsEmptyNonFiniteNegativeAndZeroTotal() {
        XCTAssertNil(PlaybackTimeline(durations: []))
        XCTAssertNil(PlaybackTimeline(durations: [10, .nan]))
        XCTAssertNil(PlaybackTimeline(durations: [10, .infinity]))
        XCTAssertNil(PlaybackTimeline(durations: [10, -1]))
        XCTAssertNil(PlaybackTimeline(durations: [0, 0]))
    }

    func testLocationInFirstMiddleAndLastFile() throws {
        let timeline = try makeTimeline([95, 61, 127])
        XCTAssertEqual(timeline.location(for: 10), .init(segmentIndex: 0, offset: 10))
        XCTAssertEqual(timeline.location(for: 100), .init(segmentIndex: 1, offset: 5))
        XCTAssertEqual(timeline.location(for: 200), .init(segmentIndex: 2, offset: 44))
    }

    func testExactBoundaryMapsToStartOfNextFile() throws {
        let timeline = try makeTimeline([95, 61, 127])
        XCTAssertEqual(timeline.location(for: 95), .init(segmentIndex: 1, offset: 0))
        XCTAssertEqual(timeline.location(for: 156), .init(segmentIndex: 2, offset: 0))
    }

    func testWithinEpsilonOfBoundaryMapsToStartOfNextFile() throws {
        let timeline = try makeTimeline([95, 61, 127])
        let location = timeline.location(for: 95 - PlaybackTimeline.boundaryEpsilon / 2)
        XCTAssertEqual(location.segmentIndex, 1)
        XCTAssertEqual(location.offset, 0)
    }

    func testBeyondEndClampsToEndOfLastFile() throws {
        let timeline = try makeTimeline([95, 61, 127])
        XCTAssertEqual(timeline.location(for: 10_000), .init(segmentIndex: 2, offset: 127))
        XCTAssertEqual(timeline.clamp(10_000), 283)
    }

    func testNaNAndNegativeClampToZero() throws {
        let timeline = try makeTimeline([95, 61])
        XCTAssertEqual(timeline.clamp(.nan), 0)
        XCTAssertEqual(timeline.clamp(-5), 0)
        XCTAssertEqual(timeline.location(for: .nan), .init(segmentIndex: 0, offset: 0))
        XCTAssertEqual(timeline.globalTime(segmentIndex: 1, offset: .nan), 95)
    }

    func testGlobalTimeClampsOffsetToFile() throws {
        let timeline = try makeTimeline([95, 61])
        XCTAssertEqual(timeline.globalTime(segmentIndex: 1, offset: 10), 105)
        XCTAssertEqual(timeline.globalTime(segmentIndex: 1, offset: 500), 156)
        XCTAssertEqual(timeline.globalTime(segmentIndex: 0, offset: -3), 0)
        XCTAssertEqual(timeline.globalTime(segmentIndex: 7, offset: 3), 0)
    }

    func testRoundTripAwayFromBoundaries() throws {
        let timeline = try makeTimeline([95, 61, 127])
        var time = 0.0
        while time < timeline.duration {
            let isNearBoundary = timeline.segments.dropLast().contains {
                abs($0.end - time) <= PlaybackTimeline.boundaryEpsilon
            }
            if !isNearBoundary {
                let location = timeline.location(for: time)
                XCTAssertEqual(
                    timeline.globalTime(segmentIndex: location.segmentIndex, offset: location.offset),
                    time,
                    accuracy: 0.0001
                )
            }
            time += 0.37
        }
    }

    func testZeroLengthSegmentIsKeptForAlignmentButNeverResolved() throws {
        let timeline = try makeTimeline([10, 0, 20])
        XCTAssertEqual(timeline.segments.count, 3)
        XCTAssertEqual(timeline.location(for: 10), .init(segmentIndex: 2, offset: 0))
        XCTAssertEqual(timeline.location(for: 15), .init(segmentIndex: 2, offset: 5))
        XCTAssertEqual(timeline.nextPlayableSegment(after: 0), 2)
        XCTAssertNil(timeline.nextPlayableSegment(after: 2))
    }

    func testPlaybackOrderUsesServerOrderUnlessEveryTrackHasOffset() {
        let complete: [(name: String, offset: Double?)] = [("b", 50), ("a", 0), ("c", 90)]
        XCTAssertEqual(PlaybackTimeline.playbackOrder(complete, startOffset: \.offset).map(\.name), ["a", "b", "c"])

        let partial: [(name: String, offset: Double?)] = [("b", 50), ("a", nil), ("c", 90)]
        XCTAssertEqual(PlaybackTimeline.playbackOrder(partial, startOffset: \.offset).map(\.name), ["b", "a", "c"])
    }

    func testSingleFileSourceIsHintAndRefinesFromMeasuredDuration() throws {
        let url = URL(fileURLWithPath: "/tmp/book.m4b")
        let source = PlaybackSource.singleFile(url: url, duration: 1, bookID: nil)
        XCTAssertTrue(source.durationIsHint)
        XCTAssertTrue(source.isLocal)
        XCTAssertEqual(source.timeline.duration, 1)

        let refined = source.withMeasuredDuration(3_600)
        XCTAssertFalse(refined.durationIsHint)
        XCTAssertEqual(refined.timeline.duration, 3_600)
        XCTAssertEqual(refined.identityURL, url)
        XCTAssertEqual(refined.withMeasuredDuration(10).timeline.duration, 3_600)
    }

    func testSingleFileSourceUsesPlaceholderForInvalidDuration() {
        let source = PlaybackSource.singleFile(url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: .nan, bookID: nil)
        XCTAssertEqual(source.timeline.duration, 1)
    }

    func testSourceRejectsMismatchedTrackCount() throws {
        let timeline = try makeTimeline([10, 20])
        XCTAssertNil(PlaybackSource(
            bookID: nil,
            identityURL: URL(fileURLWithPath: "/tmp/a"),
            trackURLs: [URL(fileURLWithPath: "/tmp/a")],
            timeline: timeline
        ))
    }

    func testRemoteSourceIsNotLocal() throws {
        let timeline = try makeTimeline([10, 20])
        let urls = [URL(string: "https://abs.example/api/items/1/file/1")!, URL(string: "https://abs.example/api/items/1/file/2")!]
        let source = try XCTUnwrap(PlaybackSource(bookID: nil, identityURL: urls[0], trackURLs: urls, timeline: timeline))
        XCTAssertFalse(source.isLocal)
        XCTAssertTrue(source.coversWholeBook)
    }
}
