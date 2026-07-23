import Foundation
import SwiftData
import XCTest
@testable import StoryCast

/// Regression tests for the Group D final bug-hunt fixes.
@MainActor
final class GroupDFinalFixTests: XCTestCase {

    // MARK: - S1 — SyncOutboxCompactor must not throw on corrupt dependency data

    func testCompactorSkipsCorruptDependencyData() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let good = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-good",
            in: context
        )
        let corrupt = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-corrupt",
            in: context
        )
        corrupt.dependencyData = Data([0xFF, 0x00, 0xDE, 0xAD])
        corrupt.stateRaw = "sent"
        good.stateRaw = "sent"
        try context.save()

        // Before the fix, compact() threw on the corrupt row and skipped
        // context.save(), losing markSent bookkeeping for the whole batch.
        XCTAssertNoThrow(try SyncOutboxCompactor.compact(in: context))
    }

    // MARK: - U1 — LibrarySearchHandler must return fresh results during debounce

    func testSearchFilterReturnsFreshResultsDuringDebounce() async throws {
        let handler = LibrarySearchHandler()

        let book1 = Book(title: "The Great Gatsby", duration: 3600)
        let book2 = Book(title: "War and Peace", duration: 7200)
        let allBooks = [book1, book2]

        // Set search text — the debounced task has not fired yet.
        handler.updateSearchText("gatsby", folders: [], books: allBooks)

        // Synchronously call getFilteredBooks. Before the fix, this returned
        // the stale cache (empty or from a previous query) instead of
        // filtering against the current search text.
        let results = handler.getFilteredBooks(allBooks: allBooks)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "The Great Gatsby")
    }

    func testFolderSearchFilterReturnsFreshResultsDuringDebounce() async throws {
        let handler = LibrarySearchHandler()

        let folder1 = Folder(name: "Classics", isSystem: false)
        let folder2 = Folder(name: "Modern", isSystem: false)
        let allFolders = [folder1, folder2]

        handler.updateSearchText("classics", folders: allFolders, books: [])

        let results = handler.getFilteredFolders(allFolders: allFolders)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Classics")
    }

    func testFolderBookSearchHandlerReturnsFreshResultsDuringDebounce() async throws {
        let handler = FolderBookSearchHandler()

        let book1 = Book(title: "Dune", duration: 3600)
        let book2 = Book(title: "Neuromancer", duration: 2400)
        let allBooks = [book1, book2]

        handler.updateSearchText("dune", books: allBooks)

        let results = handler.filteredBooks(from: allBooks)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Dune")
    }

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
