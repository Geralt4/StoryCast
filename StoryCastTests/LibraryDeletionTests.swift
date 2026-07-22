import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class LibraryDeletionTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @MainActor
    private func makeManagedFile(named fileName: String) async throws -> URL {
        try await StorageManager.shared.setupStoryCastLibraryDirectory()
        let fileURL = StorageManager.shared.storyCastLibraryURL.appendingPathComponent(fileName)
        try Data("audio".utf8).write(to: fileURL)
        return fileURL
    }

    @MainActor
    func testSharedAudioSurvivesFirstDeletionAndEachBookGetsOneTombstone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "deletion-shared-\(UUID().uuidString).m4b"
        let fileURL = try await makeManagedFile(named: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let first = Book(title: "First", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        let second = Book(title: "Second", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(SyncRuntime(generationID: UUID().uuidString))
        context.insert(first)
        context.insert(second)
        try context.save()

        try await LibraryBookActions(modelContext: context).deleteBook(first)

        var verification = ModelContext(container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Book>()).map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let firstTombstone = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<SyncTombstone>()).first {
                $0.entityID == first.id.uuidString.lowercased()
            }
        )
        XCTAssertEqual(firstTombstone.revision, 1)
        let firstOutbox = try verification.fetch(FetchDescriptor<SyncOutboxOperation>())
            .filter { $0.subjectID == SyncRecordName.tombstone(kind: .book, id: first.id.uuidString.lowercased()) }
        XCTAssertEqual(firstOutbox.count, 1)
        let pending = try verification.fetch(FetchDescriptor<StorageCleanupJournalEntry>())
        XCTAssertEqual(pending.map(\.relativePath), [fileName])

        let survivingBook = try XCTUnwrap(try verification.fetch(FetchDescriptor<Book>()).first)
        try await LibraryBookActions(modelContext: verification).deleteBook(survivingBook)

        verification = ModelContext(container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Book>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try verification.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
        let tombstones = try verification.fetch(FetchDescriptor<SyncTombstone>())
        XCTAssertEqual(tombstones.count, 2)
        XCTAssertTrue(tombstones.allSatisfy { $0.revision == 1 })
    }

    @MainActor
    func testBatchDeletionStagesAllPathsBeforeOneCommit() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let sharedName = "deletion-batch-shared-\(UUID().uuidString).m4b"
        let uniqueName = "deletion-batch-unique-\(UUID().uuidString).m4b"
        let sharedURL = try await makeManagedFile(named: sharedName)
        let uniqueURL = try await makeManagedFile(named: uniqueName)
        defer {
            try? FileManager.default.removeItem(at: sharedURL)
            try? FileManager.default.removeItem(at: uniqueURL)
        }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let books = [
            Book(title: "Shared A", localFileName: sharedName, duration: 100, isImported: true, folder: folder),
            Book(title: "Shared B", localFileName: sharedName, duration: 100, isImported: true, folder: folder),
            Book(title: "Unique", localFileName: uniqueName, duration: 100, isImported: true, folder: folder)
        ]
        context.insert(folder)
        context.insert(SyncRuntime(generationID: UUID().uuidString))
        for book in books { context.insert(book) }
        try context.save()

        try await LibraryBookActions(modelContext: context).deleteBooks(books)

        let verification = ModelContext(container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Book>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uniqueURL.path))
        XCTAssertTrue(try verification.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
        let tombstones = try verification.fetch(FetchDescriptor<SyncTombstone>())
        XCTAssertEqual(tombstones.count, books.count)
        XCTAssertTrue(tombstones.allSatisfy { $0.revision == 1 })
    }

    @MainActor
    func testRollbackBeforeCommitLeavesBookFileAndJournalUntouched() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "deletion-rollback-\(UUID().uuidString).m4b"
        let fileURL = try await makeManagedFile(named: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let book = Book(title: "Rollback", localFileName: fileName, duration: 100, isImported: true, folder: folder)
        context.insert(folder)
        context.insert(SyncRuntime(generationID: UUID().uuidString))
        context.insert(book)
        try context.save()

        try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: "test-device", in: context)
        context.rollback()

        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Book>()).map(\.id), [book.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try verification.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<SyncTombstone>()).isEmpty)
    }

    @MainActor
    func testFolderDeletionPersistsReassignmentAndTombstoneTogether() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let unfiled = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        let userFolder = Folder(name: "To Delete", isSystem: false, sortOrder: 1)
        let book = Book(title: "Moved", localFileName: "moved.m4b", duration: 100, isImported: true, folder: userFolder)
        context.insert(unfiled)
        context.insert(userFolder)
        context.insert(book)
        context.insert(SyncRuntime(generationID: UUID().uuidString))
        try context.save()

        try await LibraryFolderOperations(modelContext: context).deleteFolderWithDestination(userFolder, destination: unfiled)

        let verification = ModelContext(container)
        XCTAssertFalse(try verification.fetch(FetchDescriptor<Folder>()).contains { $0.id == userFolder.id })
        let movedBook = try XCTUnwrap(try verification.fetch(FetchDescriptor<Book>()).first)
        XCTAssertEqual(movedBook.folder?.id, unfiled.id)
        let tombstone = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<SyncTombstone>()).first {
                $0.entityID == userFolder.id.uuidString.lowercased()
            }
        )
        XCTAssertEqual(tombstone.entityKindRaw, SyncEntityKind.folder.rawValue)
        XCTAssertEqual(tombstone.revision, 1)
    }
}
