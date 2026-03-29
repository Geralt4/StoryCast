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
        let models = SchemaV3.models
        XCTAssertTrue(models.contains(where: { $0 == ABSServer.self }), "ABSServer should be in SchemaV3 models")
    }
    
    @MainActor
    func testMigrationPlanSupportsV1V2V3() {
        let schemas = StoryCastMigrationPlan.schemas
        XCTAssertEqual(schemas.count, 3, "Migration plan should support V1, V2, and V3")
        XCTAssertTrue(schemas.contains { $0 == SchemaV1.self })
        XCTAssertTrue(schemas.contains { $0 == SchemaV2.self })
        XCTAssertTrue(schemas.contains { $0 == SchemaV3.self })
    }
    
    @MainActor
    func testAllSchemaVersionsInMigrationPlanHaveUniqueModels() {
        let schemas = StoryCastMigrationPlan.schemas
        
        XCTAssertFalse(schemas.isEmpty, "Migration plan must have at least one schema")
        
        for i in 0..<(schemas.count - 1) {
            let currentSchema = schemas[i]
            let nextSchema = schemas[i + 1]
            
            let currentModels = currentSchema.models
                .map { String(describing: $0) }
                .sorted()
            let nextModels = nextSchema.models
                .map { String(describing: $0) }
                .sorted()
            
            XCTAssertNotEqual(
                currentModels,
                nextModels,
                "Schema versions \(currentSchema) and \(nextSchema) have identical models. " +
                "This causes NSStagedMigrationManager to crash. " +
                "Each schema version must have different models. " +
                "Current: \(currentModels), Next: \(nextModels)"
            )
        }
    }

    @MainActor
    func testPendingProgressKeyOmitsRawServerURL() {
        let store = ProgressBackupStore.shared
        let key = store.debugPendingProgressKey(serverURL: "https://abs.example.com:13378", itemId: "item123")

        XCTAssertFalse(key.contains("abs.example.com"))
        XCTAssertTrue(key.contains("item123"))
    }

    @MainActor
    func testPendingProgressBackupCanBeStoredAndCleared() {
        let serverURL = "https://abs.example.com:13378"
        let itemId = "item123"
        let store = ProgressBackupStore.shared

        store.debugClear(serverURL: serverURL, itemId: itemId)
        store.debugBackup(
            serverURL: serverURL,
            itemId: itemId,
            currentTime: 245,
            timeListened: 7,
            duration: 1000
        )

        let hasPendingProgress = store.debugHasPending(serverURL: serverURL, itemId: itemId)
        XCTAssertTrue(hasPendingProgress)

        store.debugClear(serverURL: serverURL, itemId: itemId)

        let hasPendingProgressAfterClear = store.debugHasPending(serverURL: serverURL, itemId: itemId)
        XCTAssertFalse(hasPendingProgressAfterClear)
    }

    // MARK: - Folder Operations Tests (replicating LibraryFolderOperations without the class)
    
    /// Helper to create a folder with unique name (replicates LibraryFolderOperations.createFolder)
    @MainActor
    private func createFolder(in context: ModelContext, name: String) throws -> Folder {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return try createFolder(in: context, name: "New Folder")
        }
        
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let sortOrder = (folders.map { $0.sortOrder }.max() ?? 0) + 1
        let folderName = makeUniqueName(in: context, for: trimmedName)
        
        let folder = Folder(name: folderName, isSystem: false, sortOrder: sortOrder)
        context.insert(folder)
        try context.save()
        
        return folder
    }
    
    /// Helper to make a unique folder name (replicates LibraryFolderOperations.makeUniqueName)
    @MainActor
    private func makeUniqueName(in context: ModelContext, for name: String, excluding folderId: UUID? = nil) -> String {
        guard let existingNames = try? Set(context.fetch(FetchDescriptor<Folder>())
            .filter { $0.id != folderId }
            .map { $0.name }) else {
            return name
        }
        
        guard existingNames.contains(name) else {
            return name
        }
        
        var counter = 2
        var candidateName = ""
        
        repeat {
            candidateName = "\(name) (\(counter))"
            counter += 1
        } while existingNames.contains(candidateName)
        
        return candidateName
    }
    
    /// Helper to rename a folder (replicates LibraryFolderOperations.renameFolder)
    @MainActor
    private func renameFolder(in context: ModelContext, _ folder: Folder, newName: String) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let uniqueName = makeUniqueName(in: context, for: trimmedName, excluding: folder.id)
        
        if folder.name != uniqueName {
            folder.name = uniqueName
            try context.save()
        }
    }
    
    /// Helper to delete a folder (replicates LibraryFolderOperations.deleteFolder)
    @MainActor
    private func deleteFolder(in context: ModelContext, _ folder: Folder) throws {
        // Get the Unfiled system folder
        let folders = try context.fetch(FetchDescriptor<Folder>())
        guard let unfiled = folders.first(where: { $0.isSystem }) else { return }
        
        // Move books to Unfiled
        for book in folder.books {
            book.folder = unfiled
        }
        
        context.delete(folder)
        try context.save()
    }

    @MainActor
    func testFolderSortOrderIncrementsCorrectly() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)
        
        // Create Unfiled system folder first (required for folder operations)
        let unfiled = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(unfiled)
        try context.save()
        
        let initialMaxSortOrder = try context.fetch(FetchDescriptor<Folder>()).map { $0.sortOrder }.max() ?? 0
        
        // Create folders directly without LibraryFolderOperations
        let firstFolder = try createFolder(in: context, name: "First Folder_\(UUID().uuidString)")
        let secondFolder = try createFolder(in: context, name: "Second Folder_\(UUID().uuidString)")
        
        XCTAssertEqual(secondFolder.sortOrder, firstFolder.sortOrder + 1, "Second folder should have sortOrder exactly 1 higher than first")
        XCTAssertEqual(firstFolder.sortOrder, initialMaxSortOrder + 1, "First folder should have correct sortOrder")
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
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)
        
        // Create Unfiled system folder first
        let unfiled = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(unfiled)
        try context.save()
        
        // Create folder with whitespace-only name (should default to "New Folder")
        let folder = try createFolder(in: context, name: "   ")
        XCTAssertNotNil(folder)
        XCTAssertTrue(folder.name.hasPrefix("New Folder"), "Empty folder name should fall back to a name starting with 'New Folder', got '\(folder.name)'")
    }

    @MainActor
    func testFolderOperationsPersistCorrectly() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)
        
        // Create Unfiled system folder first (required for deleteFolder to work)
        let unfiled = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(unfiled)
        try context.save()
        
        let uniqueSuffix = UUID().uuidString
        
        // Create folders
        let folder1 = try createFolder(in: context, name: "Test Folder 1_\(uniqueSuffix)")
        let folder2 = try createFolder(in: context, name: "Test Folder 2_\(uniqueSuffix)")
        
        var allFolders = try context.fetch(FetchDescriptor<Folder>())
        // 2 user folders + 1 Unfiled system folder = 3
        XCTAssertEqual(allFolders.count, 3, "Should have 3 folders after creation (2 user + 1 system)")

        // Rename folder
        try renameFolder(in: context, folder1, newName: "Renamed Folder_\(uniqueSuffix)")
        XCTAssertEqual(folder1.name, "Renamed Folder_\(uniqueSuffix)", "Folder should be renamed")

        // Delete folder
        try deleteFolder(in: context, folder2)
        allFolders = try context.fetch(FetchDescriptor<Folder>())
        // 1 user folder + 1 Unfiled system folder = 2
        XCTAssertEqual(allFolders.count, 2, "Should have 2 folders after deletion (1 user + 1 system)")
        XCTAssertTrue(allFolders.contains { $0.name == "Renamed Folder_\(uniqueSuffix)" }, "Remaining user folder should be the renamed one")
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
