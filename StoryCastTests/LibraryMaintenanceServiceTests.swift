import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class LibraryMaintenanceServiceTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeLibraryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url
    }

    private func makeAudioFile(in directory: URL, named fileName: String, contents: String = "audio") throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @MainActor
    func testRowsSharingCanonicalPathCollapseToOneKeeper() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        let fileName = "shared.m4b"
        _ = try makeAudioFile(in: libraryURL, named: fileName)

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let book1 = Book(title: "Book 1", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        let book2 = Book(title: "Book 2", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        let book3 = Book(title: "Book 3", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(book1)
        context.insert(book2)
        context.insert(book3)
        try context.save()

        let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.removedCount, 2)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.appendingPathComponent(fileName).path))
    }

    @MainActor
    func testSameMetadataDifferentPathsIsNotDeduplicated() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        _ = try makeAudioFile(in: libraryURL, named: "book-a.m4b", contents: "aaa")
        _ = try makeAudioFile(in: libraryURL, named: "book-b.m4b", contents: "bbb")

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let book1 = Book(title: "Same Title", author: "Same Author", localFileName: "book-a.m4b", duration: 100, isImported: true, folder: folder)
        let book2 = Book(title: "Same Title", author: "Same Author", localFileName: "book-b.m4b", duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(book1)
        context.insert(book2)
        try context.save()

        let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.removedCount, 0)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 2)
    }

    @MainActor
    func testDedupRerunIsIdempotent() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        let fileName = "shared.m4b"
        _ = try makeAudioFile(in: libraryURL, named: fileName)

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let book1 = Book(title: "Book 1", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        let book2 = Book(title: "Book 2", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(book1)
        context.insert(book2)
        try context.save()

        let first = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        let second = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)

        XCTAssertTrue(first.completed)
        XCTAssertEqual(first.removedCount, 1)
        XCTAssertTrue(second.completed)
        XCTAssertEqual(second.removedCount, 0)
    }

    @MainActor
    func testKeeperSelectionIsDeterministicByLastPlayedDate() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        let fileName = "shared.m4b"
        _ = try makeAudioFile(in: libraryURL, named: fileName)

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let olderDate = Date(timeIntervalSince1970: 1_000)
        let newerDate = Date(timeIntervalSince1970: 2_000)
        let book1 = Book(title: "Older", localFileName: fileName, duration: 100, lastPlayedDate: olderDate, isImported: true, folder: folder)
        let book2 = Book(title: "Newer", localFileName: fileName, duration: 100, lastPlayedDate: newerDate, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(book1)
        context.insert(book2)
        try context.save()

        let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        XCTAssertTrue(result.completed)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.title, "Newer")
    }

    @MainActor
    func testMetadataIsMergedIntoKeeperBeforeLoserDeletion() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        let fileName = "shared.m4b"
        _ = try makeAudioFile(in: libraryURL, named: fileName)

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let keeper = Book(
            title: "Keeper",
            localFileName: fileName,
            duration: 100,
            lastPlaybackPosition: 10,
            lastPlayedDate: Date(timeIntervalSince1970: 4_000),
            isImported: false,
            folder: nil
        )
        let loser = Book(
            title: "Loser",
            author: "Recovered Author",
            localFileName: fileName,
            duration: 100,
            lastPlaybackPosition: 50,
            lastPlayedDate: Date(timeIntervalSince1970: 3_000),
            isImported: true,
            folder: folder,
            coverArtFileName: "dedup-cover-\(UUID().uuidString).jpg"
        )
        let keeperChapter = Chapter(title: "Keeper Chapter", startTime: 0, endTime: 20, book: keeper)
        let chapter = Chapter(title: "Recovered Chapter", startTime: 20, endTime: 50, book: loser)
        context.insert(folder)
        context.insert(keeper)
        context.insert(loser)
        context.insert(keeperChapter)
        context.insert(chapter)
        try context.save()

        let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        XCTAssertTrue(result.completed)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.title, "Keeper")
        XCTAssertEqual(books.first?.author, "Recovered Author")
        XCTAssertEqual(books.first?.lastPlaybackPosition, 10)
        XCTAssertEqual(books.first?.lastPlayedDate, Date(timeIntervalSince1970: 4_000))
        XCTAssertTrue(books.first?.isImported == true)
        XCTAssertEqual(books.first?.folder?.id, folder.id)
        XCTAssertEqual(books.first?.coverArtFileName, loser.coverArtFileName)
        XCTAssertEqual(books.first?.chapters.map(\.title).sorted(), ["Keeper Chapter", "Recovered Chapter"])
    }

    @MainActor
    func testMissingSyncedBookIsPreservedForCloudRestore() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let libraryURL = try makeLibraryDirectory()
        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let book = Book(title: "Synced", localFileName: "missing-synced.m4b", duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(book)
        context.insert(SyncAsset(
            bookID: book.id,
            kindRaw: SyncAssetKind.audio.rawValue,
            originalFileName: book.localFileName,
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 1,
            sha256Hex: "digest",
            localRelativePath: book.localFileName,
            localStateRaw: SyncAssetLocalState.missing.rawValue,
            cloudStateRaw: SyncAssetCloudState.published.rawValue
        ))
        try context.save()

        let result = await LibraryMaintenanceService.repairLibraryIntegrity(container: container, libraryURL: libraryURL)

        XCTAssertEqual(result.staleRemovedCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).map(\.id), [book.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncTombstone>()).isEmpty)
    }
}
