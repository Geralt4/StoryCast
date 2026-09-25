import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class RemoteChapterImporterTests: XCTestCase {
    func testMapperSortsClampsDropsInvalidAndNamesBlankTitles() {
        let chapters = [
            ABSChapter(id: 2, start: 95, end: 156, title: "  "),
            ABSChapter(id: 1, start: 0, end: 95, title: "Part 1"),
            ABSChapter(id: 3, start: 156, end: 400, title: "Part 3"),
            ABSChapter(id: 4, start: 300, end: 290, title: "Broken"),
            ABSChapter(id: 5, start: .nan, end: 10, title: "NaN")
        ]

        let specs = RemoteChapterMapper.specs(from: chapters, timelineDuration: 283)

        XCTAssertEqual(specs, [
            ChapterSpec(title: "Part 1", start: 0, end: 95),
            ChapterSpec(title: "Chapter 2", start: 95, end: 156),
            ChapterSpec(title: "Part 3", start: 156, end: 283)
        ])
    }

    @MainActor
    func testReplacesChaptersInPlaceForRemoteBook() throws {
        let (context, book) = try makeBook(isRemote: true)
        let first = Chapter(title: "Embedded 1", startTime: 0, endTime: 30, source: .embedded, book: book)
        let second = Chapter(title: "Embedded 2", startTime: 30, endTime: 95, source: .embedded, book: book)
        context.insert(first)
        context.insert(second)
        try context.save()
        let specs = [
            ChapterSpec(title: "Part 1", start: 0, end: 95),
            ChapterSpec(title: "Part 2", start: 95, end: 156),
            ChapterSpec(title: "Part 3", start: 156, end: 283)
        ]

        let changed = try RemoteChapterImporter.apply(specs, trackCount: 3, to: book, in: context)

        XCTAssertTrue(changed)
        let chapters = book.chapters.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(chapters.map(\.title), ["Part 1", "Part 2", "Part 3"])
        XCTAssertEqual(chapters.map(\.endTime), [95, 156, 283])
        XCTAssertTrue(chapters.allSatisfy { $0.source == .unknown })
        // The original objects are reused rather than deleted and recreated.
        XCTAssertTrue(chapters[0] === first)
        XCTAssertTrue(chapters[1] === second)
    }

    @MainActor
    func testRemovesExtraChapters() throws {
        let (context, book) = try makeBook(isRemote: true)
        for index in 0..<4 {
            context.insert(Chapter(title: "C\(index)", startTime: Double(index) * 10, endTime: Double(index + 1) * 10, book: book))
        }
        try context.save()

        try RemoteChapterImporter.apply([ChapterSpec(title: "Only", start: 0, end: 40)], trackCount: 1, to: book, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Chapter>()).map(\.title), ["Only"])
    }

    @MainActor
    func testNoChangeWhenChaptersAlreadyMatch() throws {
        let (context, book) = try makeBook(isRemote: true)
        context.insert(Chapter(title: "Part 1", startTime: 0, endTime: 95, source: .unknown, book: book))
        try context.save()

        let changed = try RemoteChapterImporter.apply([ChapterSpec(title: "Part 1", start: 0, end: 95.001)], trackCount: 3, to: book, in: context)

        XCTAssertFalse(changed)
    }

    @MainActor
    func testEmptyServerChaptersOnMultiFileBookRemoveOnlyFileChapters() throws {
        let (context, book) = try makeBook(isRemote: true)
        context.insert(Chapter(title: "From file 1", startTime: 0, endTime: 30, source: .embedded, book: book))
        context.insert(Chapter(title: "From server", startTime: 30, endTime: 60, source: .unknown, book: book))
        try context.save()

        let changed = try RemoteChapterImporter.apply([], trackCount: 3, to: book, in: context)

        XCTAssertTrue(changed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Chapter>()).map(\.title), ["From server"])
    }

    @MainActor
    func testEmptyServerChaptersOnSingleFileBookKeepChapters() throws {
        let (context, book) = try makeBook(isRemote: true)
        context.insert(Chapter(title: "From file", startTime: 0, endTime: 30, source: .embedded, book: book))
        try context.save()

        XCTAssertFalse(try RemoteChapterImporter.apply([], trackCount: 1, to: book, in: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Chapter>()).count, 1)
    }

    @MainActor
    func testLocalBookIsNeverTouched() throws {
        let (context, book) = try makeBook(isRemote: false)
        context.insert(Chapter(title: "Local", startTime: 0, endTime: 30, source: .embedded, book: book))
        try context.save()

        let changed = try RemoteChapterImporter.apply([ChapterSpec(title: "Server", start: 0, end: 10)], trackCount: 3, to: book, in: context)

        XCTAssertFalse(changed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Chapter>()).map(\.title), ["Local"])
    }

    @MainActor
    private func makeBook(isRemote: Bool) throws -> (ModelContext, Book) {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        containers.append(container)
        let context = ModelContext(container)
        let book = Book(title: "Book", localFileName: isRemote ? "" : "book.m4b", duration: 283, isRemote: isRemote)
        context.insert(book)
        try context.save()
        return (context, book)
    }

    private var containers: [ModelContainer] = []
}
