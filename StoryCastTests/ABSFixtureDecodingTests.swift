import XCTest
@testable import StoryCast

nonisolated final class ABSFixtureDecodingTests: XCTestCase {
    func testPlayFixtureDecodesAllTracksWithInoExtAndCumulativeOffsets() throws {
        let session = try ABSFixtures.playSession("abs-play-mp3-multi")
        XCTAssertEqual(session.audioTracks.count, 3)
        XCTAssertEqual(session.audioTracks.map(\.duration), [95, 61, 127])
        XCTAssertEqual(session.audioTracks.map(\.startOffset), [0, 95, 156])
        XCTAssertTrue(session.audioTracks.allSatisfy { $0.ino?.isEmpty == false })
        XCTAssertEqual(session.audioTracks.map { $0.metadata?.ext }, [".mp3", ".mp3", ".mp3"])
        XCTAssertEqual(session.audioTracks.map(\.codec), ["mp3", "mp3", "mp3"])
        for track in session.audioTracks {
            let ino = try XCTUnwrap(track.ino)
            XCTAssertEqual(track.contentUrl, "/api/items/\(session.libraryItemId)/file/\(ino)")
        }
    }

    func testExpandedItemHasTracksAndChapters() throws {
        let item = try ABSFixtures.libraryItem("abs-item-m4a-multi")
        XCTAssertEqual(item.media.tracks?.count, 3)
        XCTAssertEqual(item.media.tracks?.map(\.duration), [70, 45, 100])
        XCTAssertEqual(item.media.numTracks, 3)
        XCTAssertEqual(item.media.chapters?.count, 3)
        XCTAssertEqual(item.media.tracks?.map { $0.metadata?.ext }, [".m4a", ".m4a", ".m4a"])
    }

    func testSessionChaptersAreInWholeBookTime() throws {
        let session = try ABSFixtures.playSession("abs-play-mp3-multi")
        let chapters = try XCTUnwrap(session.chapters)
        XCTAssertEqual(chapters.map(\.start), [0, 95, 156])
        let trackTotal = session.audioTracks.compactMap(\.duration).reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(chapters.last).end, trackTotal, accuracy: 0.01)
    }

    func testFixtureTimelineMatchesSessionDuration() throws {
        for name in ["abs-play-mp3-multi", "abs-play-m4a-multi", "abs-play-m4b-single"] {
            let session = try ABSFixtures.playSession(name)
            let ordered = PlaybackTimeline.playbackOrder(session.audioTracks, startOffset: \.startOffset)
            let timeline = try XCTUnwrap(PlaybackTimeline(durations: ordered.compactMap(\.duration)))
            XCTAssertEqual(timeline.duration, try XCTUnwrap(session.duration), accuracy: 0.01, name)
            XCTAssertEqual(timeline.segments.map(\.startOffset), ordered.compactMap(\.startOffset), name)
        }
    }

    func testLibraryPageHasTrackCountsWithoutTracks() throws {
        let page = try ABSFixtures.decode(ABSLibraryItemsResponse.self, from: "abs-library-page")
        XCTAssertEqual(page.results.count, 3)
        for item in page.results {
            XCTAssertNotNil(item.media.numTracks)
            XCTAssertNil(item.media.tracks)
        }
        XCTAssertEqual(Set(page.results.compactMap(\.media.numTracks)), [1, 3])
    }
}
