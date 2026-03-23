import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class RemoteCleanupSafetyTests: XCTestCase {
    @MainActor
    func testRemoveRemoteBooksDeletesDatabaseRowsBeforeAssets() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)

        let book = Book(
            title: "Remote Book",
            author: "Author",
            duration: 60,
            isRemote: true,
            remoteItemId: "remote-1",
            remoteLibraryId: "library-1",
            serverId: server.id,
            isDownloaded: true,
            localCachePath: "remote-cache-test.m4b",
            lastSyncDate: Date()
        )
        book.coverArtFileName = "remote-cover-test.jpg"
        context.insert(book)
        try context.save()

        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        try await StorageManager.shared.setupRemoteCoverArtDirectory()

        let cacheURL = StorageManager.shared.remoteAudioCacheURL(for: "remote-cache-test.m4b")
        let coverURL = StorageManager.shared.coverArtURL(for: "remote-cover-test.jpg", isRemote: true)
        try Data("audio".utf8).write(to: cacheURL, options: .atomic)
        try Data("cover".utf8).write(to: coverURL, options: .atomic)

        try await RemoteLibraryService.shared.removeRemoteBooks(for: server.snapshot(), container: container)

        let remainingBooks = try context.fetch(FetchDescriptor<Book>())
        XCTAssertTrue(remainingBooks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))
    }

    @MainActor
    func testRemoveDownloadedBookClearsStateAndDeletesCacheOnSuccess() async throws {
        DownloadManager.shared.debugResetState()
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let handler = LibraryRemoteBookHandler(modelContext: modelContext)
        let book = Book(
            title: "Remote Book",
            author: "Author",
            duration: 60,
            isRemote: true,
            remoteItemId: "remote-2",
            remoteLibraryId: "library-1",
            serverId: UUID(),
            isDownloaded: true,
            localCachePath: "failed-save-cache.m4b"
        )
        modelContext.insert(book)
        try modelContext.save()

        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let cacheURL = StorageManager.shared.remoteAudioCacheURL(for: "failed-save-cache.m4b")
        try Data("audio".utf8).write(to: cacheURL, options: .atomic)

        handler.removeDownloadedBook(book)
        try await Task.sleep(nanoseconds: 100_000_000)

        let persistedBook = try modelContext.fetch(FetchDescriptor<Book>()).first
        XCTAssertEqual(persistedBook?.localCachePath, nil)
        XCTAssertEqual(persistedBook?.isDownloaded, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @MainActor
    func testFinishDownloadRestoresPreviousCacheWhenSaveFails() async throws {
        DownloadManager.shared.debugResetState()
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let bookId = UUID()
        let existingFileName = "\(bookId.uuidString)_remote.m4b"
        let book = Book(
            id: bookId,
            title: "",
            author: "Author",
            duration: 60,
            isRemote: true,
            remoteItemId: "remote-3",
            remoteLibraryId: "library-1",
            serverId: UUID(),
            isDownloaded: true,
            localCachePath: existingFileName
        )
        context.insert(book)
        try context.save()

        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
        let destinationURL = StorageManager.shared.remoteAudioCacheURL(for: existingFileName)
        let previousData = Data("previous-audio".utf8)
        try previousData.write(to: destinationURL, options: .atomic)

        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4b")
        let newData = Data("new-audio".utf8)
        try newData.write(to: downloadURL, options: .atomic)

        await DownloadManager.shared.debugFinishDownload(
            bookId: bookId,
            localURL: downloadURL,
            fileExtension: "m4b",
            container: container
        )

        let persistedBook = try context.fetch(FetchDescriptor<Book>()).first
        XCTAssertEqual(persistedBook?.localCachePath, existingFileName)
        XCTAssertTrue(persistedBook?.isDownloaded ?? false)
        XCTAssertEqual(try Data(contentsOf: destinationURL), previousData)

        try? FileManager.default.removeItem(at: destinationURL)
    }

    @MainActor
    func testRemoveRemoteBooksCancelsScopedRemoteTasks() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)

        let book = Book(
            title: "Remote Book",
            author: "Author",
            duration: 60,
            isRemote: true,
            remoteItemId: "remote-4",
            remoteLibraryId: "library-1",
            serverId: server.id,
            isDownloaded: true,
            localCachePath: "remote-cancel-test.m4b"
        )
        context.insert(book)
        try context.save()

        let timeoutTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let coverArtTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let backgroundCoverArtTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        DownloadManager.shared.debugRegisterTrackedDownload(bookId: book.id, timeoutTask: timeoutTask)
        RemoteLibraryService.shared.debugRegisterCoverArtTask(coverArtTask, for: book.id)
        await BackgroundRemoteCoverArtService.shared.debugRegisterTask(backgroundCoverArtTask, for: book.id)

        try await RemoteLibraryService.shared.removeRemoteBooks(for: server.snapshot(), container: container)
        let backgroundTaskCount = await BackgroundRemoteCoverArtService.shared.debugTaskCount()

        XCTAssertEqual(DownloadManager.shared.debugDownloadCount, 0)
        XCTAssertEqual(RemoteLibraryService.shared.debugCoverArtTaskCount, 0)
        XCTAssertEqual(backgroundTaskCount, 0)
        XCTAssertTrue(timeoutTask.isCancelled)
        XCTAssertTrue(coverArtTask.isCancelled)
        XCTAssertTrue(backgroundCoverArtTask.isCancelled)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
    }
}
