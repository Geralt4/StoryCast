import Foundation

/// The span of the chapter being played, used to show the progress bar and
/// times for that chapter instead of the whole book.
nonisolated struct ChapterProgress: Equatable, Sendable {
    let start: Double
    let end: Double

    var duration: Double { max(0, end - start) }

    /// Time into the chapter at book time `time`, kept inside the chapter.
    func elapsed(at time: Double) -> Double {
        min(max(time - start, 0), duration)
    }

    /// Time left in the chapter at book time `time`.
    func remaining(at time: Double) -> Double {
        duration - elapsed(at: time)
    }

    /// Book time for a position on the chapter-length slider.
    func absoluteTime(forSliderValue value: Double) -> Double {
        start + min(max(value, 0), duration)
    }

    /// Position on the chapter-length slider for book time `time`.
    func sliderValue(forAbsoluteTime time: Double) -> Double {
        elapsed(at: time)
    }

    /// Finds the chapter that `time` is in. A time in a gap between chapters,
    /// or before the first one, uses the nearest chapter before it (the first
    /// chapter when there is none). The last chapter runs to `totalDuration`
    /// when its marker ends earlier. Returns nil when there are no usable chapters.
    static func make(at time: Double, chapters: [ChapterSpec], totalDuration: Double) -> ChapterProgress? {
        let usable = chapters
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return nil }

        let index = usable.lastIndex { $0.start <= time } ?? 0
        let chapter = usable[index]
        let isLast = index == usable.count - 1
        let end = isLast && totalDuration.isFinite ? max(chapter.end, totalDuration) : chapter.end
        return ChapterProgress(start: chapter.start, end: end)
    }
}
