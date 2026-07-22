import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class StorageCleanupCoordinatorTests: XCTestCase {
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
    func testCleanupPreservesWhitespaceIdentityAndDeduplicatesIntent() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let exactName = " cleanup-exact-\(UUID().uuidString).m4b "
        let trimmedName = exactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactURL = try await makeManagedFile(named: exactName)
        let trimmedURL = try await makeManagedFile(named: trimmedName)
        defer {
            try? FileManager.default.removeItem(at: exactURL)
            try? FileManager.default.removeItem(at: trimmedURL)
        }

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: exactName, in: context))
        XCTAssertFalse(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: exactName, in: context))
        XCTAssertTrue(StorageCleanupCoordinator.isSafeRelativePath("book\\part.m4b"))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmedURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
    }

    @MainActor
    func testCleanupRejectsTraversalAndWillNotRemoveDirectory() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try await StorageManager.shared.setupStoryCastLibraryDirectory()
        let directoryName = "cleanup-directory-\(UUID().uuidString)"
        let directoryURL = StorageManager.shared.storyCastLibraryURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertFalse(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: "../outside.m4b", in: context))
        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: directoryName, in: context))
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
    }

    @MainActor
    func testCleanupRetryMetadataPersistsAfterRemovalFailure() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "cleanup-retry-\(UUID().uuidString).m4b"
        let fileURL = try await makeManagedFile(named: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: fileName, in: context))
        try context.save()

        let error = NSError(domain: "StorageCleanupCoordinatorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected removal failure"])
        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context, removing: { _ in throw error }), 0)

        let retryContext = ModelContext(container)
        let entry = try XCTUnwrap(try retryContext.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).first)
        XCTAssertEqual(entry.attemptCount, 1)
        XCTAssertEqual(entry.lastErrorMessage, error.localizedDescription)

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: retryContext), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try retryContext.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).isEmpty)
    }

    @MainActor
    func testDrainDefersCleanupWhileAnotherBookReferencesTheFile() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "cleanup-reference-\(UUID().uuidString).m4b"
        let fileURL = try await makeManagedFile(named: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(try StorageCleanupCoordinator.stage(location: .managedLibrary, relativePath: fileName, in: context))
        let book = Book(title: "Survivor", localFileName: fileName, duration: 100, isImported: true)
        context.insert(book)
        try context.save()

        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>()).count, 1)

        context.delete(book)
        try context.save()
        XCTAssertEqual(StorageCleanupCoordinator.drainPendingCleanup(in: context), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
