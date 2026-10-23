import XCTest
@testable import StoryCast

nonisolated final class ChapterProgressTests: XCTestCase {
    private let chapters = [
        ChapterSpec(title: "One", start: 0, end: 100),
        ChapterSpec(title: "Two", start: 100, end: 250),
        ChapterSpec(title: "Three", start: 300, end: 400)
    ]

    func testMidChapterElapsedAndRemaining() throws {
        let progress = try XCTUnwrap(ChapterProgress.make(at: 130, chapters: chapters, totalDuration: 400))

        XCTAssertEqual(progress, ChapterProgress(start: 100, end: 250))
        XCTAssertEqual(progress.duration, 150)
        XCTAssertEqual(progress.elapsed(at: 130), 30)
        XCTAssertEqual(progress.remaining(at: 130), 120)
    }

    func testExactBoundaryBelongsToNextChapter() throws {
        let progress = try XCTUnwrap(ChapterProgress.make(at: 100, chapters: chapters, totalDuration: 400))

        XCTAssertEqual(progress.start, 100)
        XCTAssertEqual(progress.elapsed(at: 100), 0)
    }

    func testTimeInGapUsesPrecedingChapterAndClampsToItsEnd() throws {
        let progress = try XCTUnwrap(ChapterProgress.make(at: 270, chapters: chapters, totalDuration: 400))

        XCTAssertEqual(progress, ChapterProgress(start: 100, end: 250))
        XCTAssertEqual(progress.elapsed(at: 270), 150)
        XCTAssertEqual(progress.remaining(at: 270), 0)
    }

    func testTimeBeforeFirstChapterUsesFirstChapter() throws {
        let late = [ChapterSpec(title: "One", start: 10, end: 50)]
        let progress = try XCTUnwrap(ChapterProgress.make(at: 2, chapters: late, totalDuration: 50))

        XCTAssertEqual(progress.start, 10)
        XCTAssertEqual(progress.elapsed(at: 2), 0)
    }

    func testLastChapterRunsToTotalDuration() throws {
        let progress = try XCTUnwrap(ChapterProgress.make(at: 350, chapters: chapters, totalDuration: 420))

        XCTAssertEqual(progress, ChapterProgress(start: 300, end: 420))
        XCTAssertEqual(progress.remaining(at: 410), 10)
    }

    func testChaptersAreSortedAndInvalidOnesIgnored() throws {
        let messy = [
            ChapterSpec(title: "B", start: 50, end: 100),
            ChapterSpec(title: "Bad", start: 70, end: 70),
            ChapterSpec(title: "A", start: 0, end: 50)
        ]
        let progress = try XCTUnwrap(ChapterProgress.make(at: 20, chapters: messy, totalDuration: 100))

        XCTAssertEqual(progress, ChapterProgress(start: 0, end: 50))
    }

    func testNoUsableChaptersReturnsNil() {
        XCTAssertNil(ChapterProgress.make(at: 10, chapters: [], totalDuration: 100))
        XCTAssertNil(ChapterProgress.make(at: 10, chapters: [ChapterSpec(title: "x", start: 5, end: 5)], totalDuration: 100))
    }

    func testSliderMappingRoundTripsAndClamps() {
        let progress = ChapterProgress(start: 100, end: 250)

        XCTAssertEqual(progress.sliderValue(forAbsoluteTime: 130), 30)
        XCTAssertEqual(progress.absoluteTime(forSliderValue: 30), 130)
        XCTAssertEqual(progress.absoluteTime(forSliderValue: 999), 250)
        XCTAssertEqual(progress.absoluteTime(forSliderValue: -5), 100)
    }
}
