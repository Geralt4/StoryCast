import Foundation

/// Book time laid out across one or more audio files.
///
/// Audiobookshelf serves a book stored as several files as one track per file,
/// each with its own duration. Everything outside the player (progress, chapters,
/// sync, Now Playing) works in whole-book seconds; this type maps between that
/// book time and a position inside a single file.
///
/// Segments stay index-aligned with the source's tracks. Zero-length segments are
/// kept for alignment but never resolved to, so the player never enqueues them.
nonisolated struct PlaybackTimeline: Sendable, Equatable {
    nonisolated struct Segment: Sendable, Equatable {
        let startOffset: Double
        let duration: Double
        var end: Double { startOffset + duration }
    }

    nonisolated struct Location: Sendable, Equatable {
        let segmentIndex: Int
        let offset: Double
    }

    /// Times this close to the end of a file resolve to the start of the next
    /// file, so a resume or chapter seek never lands on a file's last frames.
    static let boundaryEpsilon: Double = 0.25

    let segments: [Segment]

    var duration: Double { segments.last?.end ?? 0 }

    /// Builds cumulative offsets from per-file durations. Returns nil for an
    /// empty list, a non-finite or negative duration, or a zero total.
    init?(durations: [Double]) {
        guard !durations.isEmpty,
              durations.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        var offset = 0.0
        var segments: [Segment] = []
        segments.reserveCapacity(durations.count)
        for duration in durations {
            segments.append(Segment(startOffset: offset, duration: duration))
            offset += duration
        }
        guard offset > 0 else { return nil }
        self.segments = segments
    }

    /// NaN and negative times map to 0; times past the end map to the end.
    func clamp(_ time: Double) -> Double {
        guard time.isFinite, time > 0 else { return 0 }
        return min(time, duration)
    }

    func location(for time: Double) -> Location {
        let target = clamp(time)
        let playable = segments.indices.filter { segments[$0].duration > 0 }
        guard let last = playable.last else { return Location(segmentIndex: 0, offset: 0) }

        for index in playable where index != last {
            let segment = segments[index]
            if target < segment.end - Self.boundaryEpsilon {
                return Location(segmentIndex: index, offset: max(0, target - segment.startOffset))
            }
        }
        let lastSegment = segments[last]
        let offset = min(max(0, target - lastSegment.startOffset), lastSegment.duration)
        return Location(segmentIndex: last, offset: offset)
    }

    func globalTime(segmentIndex: Int, offset: Double) -> Double {
        guard segments.indices.contains(segmentIndex) else { return 0 }
        let segment = segments[segmentIndex]
        let safeOffset = offset.isFinite ? min(max(0, offset), segment.duration) : 0
        return segment.startOffset + safeOffset
    }

    /// The index of the first playable segment after `index`, if any.
    func nextPlayableSegment(after index: Int) -> Int? {
        segments.indices.first { $0 > index && segments[$0].duration > 0 }
    }

    /// Orders server tracks for playback. The server's array order is the play
    /// order; it is re-sorted by `startOffset` only when every track has one.
    static func playbackOrder<Track>(_ tracks: [Track], startOffset: (Track) -> Double?) -> [Track] {
        let offsets = tracks.map(startOffset)
        guard offsets.allSatisfy({ $0?.isFinite == true }) else { return tracks }
        return tracks.enumerated()
            .sorted { lhs, rhs in
                let left = offsets[lhs.offset] ?? 0
                let right = offsets[rhs.offset] ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}

/// Everything the player needs to play one book: its files in order, their
/// timeline, and how to authenticate requests for them.
nonisolated struct PlaybackSource: Sendable, Equatable {
    let bookID: UUID?
    /// Stable identity used by existing consumers of `AudioPlayerService.currentURL`:
    /// the audio file for a single local file, the download folder for a folder
    /// download, or the first track URL for a stream.
    let identityURL: URL
    let trackURLs: [URL]
    let timeline: PlaybackTimeline
    let httpHeaders: [String: String]
    /// True when the timeline duration is only a caller-supplied guess (a single
    /// file whose real length is read from the asset once it loads).
    let durationIsHint: Bool
    /// False for sources that may hold only part of the book (an old single-file
    /// download not yet verified). Such sources never mark the book finished and
    /// never push a position to the server.
    let coversWholeBook: Bool

    var isLocal: Bool { trackURLs.allSatisfy(\.isFileURL) }

    init?(
        bookID: UUID?,
        identityURL: URL,
        trackURLs: [URL],
        timeline: PlaybackTimeline,
        httpHeaders: [String: String] = [:],
        durationIsHint: Bool = false,
        coversWholeBook: Bool = true
    ) {
        guard !trackURLs.isEmpty, trackURLs.count == timeline.segments.count else { return nil }
        self.bookID = bookID
        self.identityURL = identityURL
        self.trackURLs = trackURLs
        self.timeline = timeline
        self.httpHeaders = httpHeaders
        self.durationIsHint = durationIsHint
        self.coversWholeBook = coversWholeBook
    }

    /// One file whose length is refined from the asset after loading.
    static func singleFile(
        url: URL,
        duration: Double,
        bookID: UUID?,
        httpHeaders: [String: String] = [:],
        coversWholeBook: Bool = true
    ) -> PlaybackSource {
        let hint = duration.isFinite && duration > 0 ? duration : 1
        // A single positive duration always yields a timeline.
        let timeline = PlaybackTimeline(durations: [hint])!
        return PlaybackSource(
            bookID: bookID,
            identityURL: url,
            trackURLs: [url],
            timeline: timeline,
            httpHeaders: httpHeaders,
            durationIsHint: true,
            coversWholeBook: coversWholeBook
        )!
    }

    /// A copy whose single-file timeline uses the length measured from the asset.
    func withMeasuredDuration(_ measured: Double) -> PlaybackSource {
        guard durationIsHint, trackURLs.count == 1,
              measured.isFinite, measured > 0,
              let timeline = PlaybackTimeline(durations: [measured]),
              let refined = PlaybackSource(
                bookID: bookID,
                identityURL: identityURL,
                trackURLs: trackURLs,
                timeline: timeline,
                httpHeaders: httpHeaders,
                durationIsHint: false,
                coversWholeBook: coversWholeBook
              ) else {
            return self
        }
        return refined
    }
}
