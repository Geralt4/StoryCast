import XCTest
import AVFoundation
import SwiftData
@testable import StoryCast

/// Filenames that change under NFKC normalization (full-width punctuation,
/// "…", "™", U+3000) are ordinary audiobook names that import accepts. They
/// must stay playable and must survive startup maintenance.
nonisolated final class UnicodeFileNameRegressionTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
    }

    private static let compatibilityNames = [
        "三体（上）.wav",
        "Book™.wav",
        "三体\u{3000}上.wav",
        "Wait\u{2026}.wav",
        "Book \u{FF11}.wav",
        "Caf\u{00E9}.wav",
        "Cafe\u{0301}.wav",
    ]

    func testSafeRelativePathAcceptsCompatibilityCharacters() {
        for name in Self.compatibilityNames {
            XCTAssertTrue(StorageCleanupCoordinator.isSafeRelativePath(name), "\(name) should be accepted")
        }
    }

    func testSafeRelativePathRejectsNamesThatNormalizeToTraversal() {
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath("\u{FF0E}"))
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath("\u{FF0E}\u{FF0E}"))
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath("a\u{FF0F}b.m4b"))
    }

    @MainActor
    func testStartupMaintenancePreservesBooksWithCompatibilityCharacters() async throws {
        for name in Self.compatibilityNames {
            let container = try makeInMemoryContainer()
            let libraryURL = try makeTemporaryDirectory()
            _ = try makeTemporaryAudioFile(in: libraryURL, named: name)
            let bookID = try insertBook(named: name, in: container)

            let book = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Book>()).first)
            XCTAssertNotNil(PlayerViewModel(book: book).bookAudioURL, "\(name) should be playable")

            for _ in 1...2 {
                try await runStartupMaintenance(container: container, libraryURL: libraryURL)
                let books = try ModelContext(container).fetch(FetchDescriptor<Book>())
                XCTAssertEqual(books.count, 1, "\(name) should not be deleted or re-adopted")
                let survivor = try XCTUnwrap(books.first)
                XCTAssertEqual(survivor.id, bookID, "\(name) lost its identity")
                XCTAssertEqual(survivor.lastPlaybackPosition, 0.1234, "\(name) lost its progress")
                XCTAssertEqual(survivor.folder?.name, "Sci-Fi", "\(name) lost its folder")
                XCTAssertEqual(survivor.chapters.count, 1, "\(name) lost its chapters")
            }
        }
    }

    @MainActor
    func testIntegrityRepairDoesNotDeleteBookWhoseNameFailsValidation() async throws {
        let container = try makeInMemoryContainer()
        let libraryURL = try makeTemporaryDirectory()
        let bookID = try insertBook(named: "\u{FF0E}\u{FF0E}", in: container)

        try await runStartupMaintenance(container: container, libraryURL: libraryURL)

        let books = try ModelContext(container).fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.map(\.id), [bookID])
    }

    // MARK: - Helpers

    @MainActor
    private func runStartupMaintenance(container: ModelContainer, libraryURL: URL) async throws {
        // Same order as StartupCoordinator.scheduleMaintenanceIfNeeded.
        _ = await LibraryMaintenanceService.repairLibraryIntegrity(container: container, libraryURL: libraryURL)
        _ = await LibraryMaintenanceService.adoptManagedLibraryFiles(container: container, libraryURL: libraryURL)
        _ = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
    }

    @MainActor
    private func insertBook(named fileName: String, in container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        let userFolder = Folder(name: "Sci-Fi", isSystem: false, sortOrder: 1)
        let book = Book(
            title: "Title",
            localFileName: fileName,
            duration: 0.2,
            lastPlaybackPosition: 0.1234,
            lastPlayedDate: Date(timeIntervalSince1970: 1_700_000_000),
            isImported: true,
            folder: userFolder
        )
        context.insert(Folder(name: "Unfiled", isSystem: true, sortOrder: 0))
        context.insert(userFolder)
        context.insert(book)
        context.insert(Chapter(title: "Chapter 1", startTime: 0, endTime: 0.1, source: .embedded, book: book))
        try context.save()
        return book.id
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnicodeFileName_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        tempURLs.append(directoryURL)
        return directoryURL
    }

    private func makeTemporaryAudioFile(in directoryURL: URL, named fileName: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(fileName)
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 5)) else {
            throw NSError(domain: "UnicodeFileNameRegressionTests", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try audioFile.write(from: buffer)
        return fileURL
    }
}
