import Foundation
import SwiftData

nonisolated struct ChapterSpec: Sendable, Equatable {
    let title: String
    let start: Double
    let end: Double
}

/// Turns Audiobookshelf chapters (whole-book time) into chapters that fit the
/// playable timeline.
nonisolated enum RemoteChapterMapper {
    static func specs(from chapters: [ABSChapter], timelineDuration: Double) -> [ChapterSpec] {
        chapters
            .sorted { $0.start < $1.start }
            .enumerated()
            .compactMap { index, chapter in
                guard chapter.start.isFinite, chapter.end.isFinite else { return nil }
                let start = max(0, chapter.start)
                let end = timelineDuration > 0 ? min(chapter.end, timelineDuration) : chapter.end
                guard end > start else { return nil }
                let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChapterSpec(title: title.isEmpty ? "Chapter \(index + 1)" : title, start: start, end: end)
            }
    }
}

/// Keeps a remote book's chapters in line with the server's chapters.
///
/// Existing `Chapter` objects are updated in place and only extra ones are
/// inserted or deleted, so an open chapter list never holds deleted models.
/// Server chapters are stored with `ChapterSource.unknown`; `.embedded` stays
/// reserved for chapters read from a file, which lets a multi-file book shed
/// the wrong chapters that were once read from its first file only.
@MainActor
enum RemoteChapterImporter {
    private static let tolerance = 0.01

    /// Returns true when the book's chapters changed.
    @discardableResult
    static func apply(_ specs: [ChapterSpec], trackCount: Int, to book: Book, in context: ModelContext) throws -> Bool {
        guard book.isRemote else { return false }
        let existing = book.chapters.sorted { $0.startTime < $1.startTime }

        guard !specs.isEmpty else {
            guard trackCount > 1 else { return false }
            let fileChapters = existing.filter { $0.source == .embedded }
            guard !fileChapters.isEmpty else { return false }
            fileChapters.forEach(context.delete)
            try context.save()
            return true
        }

        guard !matches(existing, specs) else { return false }
        for (index, spec) in specs.enumerated() {
            if existing.indices.contains(index) {
                let chapter = existing[index]
                chapter.title = spec.title
                chapter.startTime = spec.start
                chapter.endTime = spec.end
                chapter.source = .unknown
            } else {
                context.insert(Chapter(title: spec.title, startTime: spec.start, endTime: spec.end, source: .unknown, book: book))
            }
        }
        existing.dropFirst(specs.count).forEach(context.delete)
        try context.save()
        return true
    }

    private static func matches(_ chapters: [Chapter], _ specs: [ChapterSpec]) -> Bool {
        guard chapters.count == specs.count else { return false }
        return zip(chapters, specs).allSatisfy { chapter, spec in
            chapter.title == spec.title
                && abs(chapter.startTime - spec.start) < tolerance
                && abs(chapter.endTime - spec.end) < tolerance
        }
    }
}
