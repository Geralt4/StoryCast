import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class BugFixRegressionTests: XCTestCase {

    @MainActor
    func testDownloadManagerTimeoutTaskRegistrationReplacesAndCancelsPreviousTask() {
        let manager = DownloadManager.shared
        let bookId = UUID()

        let firstTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        manager.debugRegisterTimeoutTask(firstTask, for: bookId)
        XCTAssertEqual(manager.debugTimeoutTaskCount, 1)

        let secondTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        manager.debugRegisterTimeoutTask(secondTask, for: bookId)

        XCTAssertEqual(manager.debugTimeoutTaskCount, 1)
        XCTAssertTrue(firstTask.isCancelled, "Replacing timeout task should cancel the previous task")

        manager.debugCancelTimeoutTask(for: bookId)
        XCTAssertEqual(manager.debugTimeoutTaskCount, 0)
        XCTAssertTrue(secondTask.isCancelled, "Cancelling timeout task should cancel the active task")
    }

    @MainActor
    func testDownloadManagerDebugHelpersWork() async {
        let manager = DownloadManager.shared
        manager.debugResetState()
        XCTAssertEqual(manager.debugDownloadCount, 0, "Should start with no downloads")
        
        let bookId = UUID()
        manager.debugRegisterTrackedDownload(bookId: bookId)
        XCTAssertEqual(manager.debugDownloadCount, 1, "Should have one tracked download")
        
        manager.debugResetState()
        XCTAssertEqual(manager.debugDownloadCount, 0, "Should have no downloads after reset")
    }

    @MainActor
    func testResolveUnfiledFolderCreatesAndReusesSingleSystemFolder() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Folder.self, configurations: config)
        let context = ModelContext(container)

        let createdFolder = try FolderService.resolveUnfiledFolder(in: context)
        XCTAssertTrue(createdFolder.isSystem)
        XCTAssertEqual(createdFolder.name, "Unfiled")

        let reusedFolder = try FolderService.resolveUnfiledFolder(in: context)
        XCTAssertEqual(reusedFolder.id, createdFolder.id)

        let allFolders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(allFolders.filter(\.isSystem).count, 1)
    }

    @MainActor
    func testSchemaVersionIsV3() {
        // Verify that the app is using SchemaV3 which includes ABSServer
        let models = SchemaV3.models
        XCTAssertTrue(models.contains(where: { $0 == ABSServer.self }), "ABSServer should be in SchemaV3 models")
    }

    func testPendingProgressKeyOmitsRawServerURL() async {
        let store = await MainActor.run { ProgressBackupStore.shared }
        let key = await MainActor.run {
            store.debugPendingProgressKey(serverURL: "https://abs.example.com:13378", itemId: "item123")
        }

        XCTAssertFalse(key.contains("abs.example.com"))
        XCTAssertTrue(key.contains("item123"))
    }

    func testPendingProgressBackupCanBeStoredAndCleared() async {
        let serverURL = "https://abs.example.com:13378"
        let itemId = "item123"
        let store = await MainActor.run { ProgressBackupStore.shared }

        await MainActor.run {
            store.debugClear(serverURL: serverURL, itemId: itemId)
            store.debugBackup(
                serverURL: serverURL,
                itemId: itemId,
                currentTime: 245,
                timeListened: 7,
                duration: 1000
            )
        }

        let hasPendingProgress = await MainActor.run {
            store.debugHasPending(serverURL: serverURL, itemId: itemId)
        }
        XCTAssertTrue(hasPendingProgress)

        await MainActor.run {
            store.debugClear(serverURL: serverURL, itemId: itemId)
        }

        let hasPendingProgressAfterClear = await MainActor.run {
            store.debugHasPending(serverURL: serverURL, itemId: itemId)
        }
        XCTAssertFalse(hasPendingProgressAfterClear)
    }

    @MainActor
    func testFolderSortOrderIncrementsCorrectly() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
        let context = ModelContext(container)
        let operations = LibraryFolderOperations(modelContext: context)
        
        let firstFolder = operations.createFolder(name: "First Folder")
        let secondFolder = operations.createFolder(name: "Second Folder")
        
        XCTAssertEqual(secondFolder.sortOrder, firstFolder.sortOrder + 1, "Second folder should have sortOrder exactly 1 higher than first")
    }

    @MainActor
    func testRemoteCommandHandlerIsPlayingIsWritable() {
        let handler = RemoteCommandHandler.shared
        handler.isPlaying = true
        XCTAssertTrue(handler.isPlaying, "RemoteCommandHandler.isPlaying should be settable to true")
        handler.isPlaying = false
        XCTAssertFalse(handler.isPlaying, "RemoteCommandHandler.isPlaying should be settable to false")
    }

    @MainActor
    func testCreateFolderWithEmptyNameUsesDefaultName() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
        let context = ModelContext(container)
        let operations = LibraryFolderOperations(modelContext: context)
        
        let folder = operations.createFolder(name: "   ")
        XCTAssertNotNil(folder)
        XCTAssertEqual(folder.name, "New Folder", "Empty folder name should fall back to 'New Folder'")
    }

    @MainActor
    func testFolderOperationsPersistCorrectly() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
        let context = ModelContext(container)
        let operations = LibraryFolderOperations(modelContext: context)

        let folder1 = operations.createFolder(name: "Test Folder 1")
        let folder2 = operations.createFolder(name: "Test Folder 2")
        
        var allFolders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(allFolders.count, 2, "Should have 2 folders after creation")

        operations.renameFolder(folder1, newName: "Renamed Folder")
        XCTAssertEqual(folder1.name, "Renamed Folder", "Folder should be renamed")

        operations.deleteFolder(folder2)
        allFolders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(allFolders.count, 1, "Should have 1 folder after deletion")
        XCTAssertEqual(allFolders.first?.name, "Renamed Folder", "Remaining folder should be the renamed one")
    }

    @MainActor
    func testCoverArtRetryTasksAreTrackedAndCancellable() {
        let coordinator = RemoteLibraryUICoverArtCoordinator.shared
        coordinator.debugResetState()
        
        let bookId = UUID()
        let longRunningTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        coordinator.debugRegisterTask(longRunningTask, for: bookId)
        XCTAssertEqual(coordinator.debugTaskCount, 1, "Task should be tracked")
        
        coordinator.cancelAllCoverArtDownloads()
        XCTAssertEqual(coordinator.debugTaskCount, 0, "Task should be removed after cancellation")
        XCTAssertTrue(longRunningTask.isCancelled, "Task should be cancelled")
    }

    @MainActor
    func testABSServerSnapshotExtractsValuesCorrectly() {
        let server = ABSServer(
            name: "Test Server",
            url: "https://example.com:13378/",
            username: "testuser",
            userId: "user-123",
            defaultLibraryId: "library-456"
        )
        
        let snapshot = server.snapshot()
        
        XCTAssertEqual(snapshot.name, "Test Server")
        XCTAssertEqual(snapshot.username, "testuser")
        XCTAssertEqual(snapshot.userId, "user-123")
        XCTAssertEqual(snapshot.defaultLibraryId, "library-456")
        XCTAssertEqual(snapshot.normalizedURL, "https://example.com:13378")
        XCTAssertFalse(snapshot.normalizedURL.hasSuffix("/"), "normalizedURL should not have trailing slash")
    }
    
    @MainActor
    func testABSServerNormalizedURLIsPrecomputed() {
        let server = ABSServer(
            name: "Test",
            url: "https://abs.home.local:13378/",
            username: "user"
        )
        
        XCTAssertFalse(server.normalizedURL.isEmpty, "normalizedURL should be pre-computed at init")
        XCTAssertEqual(server.normalizedURL, "https://abs.home.local:13378")
    }
}
