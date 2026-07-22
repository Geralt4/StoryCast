import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class ImportDuplicateDetectorTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @MainActor
    private func writeManagedFile(named name: String, data: Data) async throws -> URL {
        try await StorageManager.shared.setupStoryCastLibraryDirectory()
        let url = StorageManager.shared.storyCastLibraryURL.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeStagedFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor
    func testDuplicateDetectionRequiresMatchingContentHash() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "import-duplicate-\(UUID().uuidString).m4b"
        let existingURL = try await writeManagedFile(named: fileName, data: Data("same bytes".utf8))
        let identicalURL = try writeStagedFile(named: "import-identical-\(UUID().uuidString).m4b", data: Data("same bytes".utf8))
        let distinctURL = try writeStagedFile(named: "import-distinct-\(UUID().uuidString).m4b", data: Data("same-bytez".utf8))
        defer {
            try? FileManager.default.removeItem(at: existingURL)
            try? FileManager.default.removeItem(at: identicalURL)
            try? FileManager.default.removeItem(at: distinctURL)
        }

        context.insert(Book(title: "Same Title", author: "Existing", localFileName: fileName, duration: 120, isImported: true))
        try context.save()

        let identicalIsDuplicate = try await ImportDuplicateDetector.shared.isDuplicate(
            title: "Same Title",
            duration: 120,
            author: "Different Author",
            fileSize: Int64(Data("same bytes".utf8).count),
            stagedFileURL: identicalURL,
            in: context
        )
        XCTAssertTrue(identicalIsDuplicate)
        let distinctIsDuplicate = try await ImportDuplicateDetector.shared.isDuplicate(
            title: "Same Title",
            duration: 120,
            author: "Existing",
            fileSize: Int64(Data("same-bytez".utf8).count),
            stagedFileURL: distinctURL,
            in: context
        )
        XCTAssertFalse(distinctIsDuplicate)
    }

    @MainActor
    func testDuplicateDetectionFailsOpenWhenHashCannotBeRead() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let fileName = "import-unreadable-\(UUID().uuidString).m4b"
        let existingURL = try await writeManagedFile(named: fileName, data: Data("same bytes".utf8))
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).m4b")
        defer { try? FileManager.default.removeItem(at: existingURL) }

        context.insert(Book(title: "Same Title", author: "Existing", localFileName: fileName, duration: 120, isImported: true))
        try context.save()

        let missingHashIsDuplicate = try await ImportDuplicateDetector.shared.isDuplicate(
            title: "Same Title",
            duration: 120,
            author: "Existing",
            fileSize: Int64(Data("same bytes".utf8).count),
            stagedFileURL: missingURL,
            in: context
        )
        XCTAssertFalse(missingHashIsDuplicate)
    }
}
