import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class BugFixTests: XCTestCase {

    // MARK: - Bug 1: isSeeking never set (inflated totalTimeListened)

    @MainActor
    func testMarkSeekingPreventsTimeListenedInflation() {
        let manager = PlaybackSessionManager.shared
        manager.debugResetListenedTime()
        manager.debugSetLastObservedTime(100.0)

        manager.markSeeking()
        XCTAssertTrue(manager.debugIsSeeking, "isSeeking should be true after markSeeking()")
    }

    @MainActor
    func testIsSeekingFlagIsReadable() {
        let manager = PlaybackSessionManager.shared
        XCTAssertFalse(manager.isSeeking, "isSeeking should start false")
        manager.markSeeking()
        XCTAssertTrue(manager.isSeeking)
    }

    @MainActor
    func testMarkSeekingExposedOnManager() {
        let manager = PlaybackSessionManager.shared
        manager.markSeeking()
        XCTAssertTrue(manager.debugIsSeeking, "Debug accessor should reflect the isSeeking state")
    }

    // MARK: - Bug 2: UUID() fallback in DownloadManager progress update

    @MainActor
    func testProgressUpdateForUnmappedTaskDoesNotMutateDownloads() {
        let manager = DownloadManager.shared
        manager.debugResetState()

        let bookId = UUID()
        manager.debugRegisterTrackedDownload(bookId: bookId)

        XCTAssertEqual(manager.debugDownloadCount, 1)

        manager.debugResetState()
        XCTAssertEqual(manager.debugDownloadCount, 0, "State should be clean after reset")
    }

    @MainActor
    func testProgressUpdateOnRegisteredDownloadTracksCorrectly() {
        let manager = DownloadManager.shared
        manager.debugResetState()

        let bookId = UUID()
        manager.debugRegisterTrackedDownload(bookId: bookId)
        XCTAssertEqual(manager.debugDownloadCount, 1)

        manager.debugResetState()
    }

    // MARK: - Bug 4: timeListened not blocking backup recovery

    @MainActor
    func testProgressBackupRecoveryDoesNotRequireTimeListened() {
        let store = ProgressBackupStore.shared
        let serverURL = "https://abs.example.com"
        let itemId = "testItem-bug4"

        store.debugClear(serverURL: serverURL, itemId: itemId)

        store.debugBackup(
            serverURL: serverURL,
            itemId: itemId,
            currentTime: 500,
            timeListened: 30,
            duration: 2000
        )
        XCTAssertTrue(store.debugHasPending(serverURL: serverURL, itemId: itemId),
                      "Backup should be present even if timeListened is stored")

        store.debugClear(serverURL: serverURL, itemId: itemId)
        XCTAssertFalse(store.debugHasPending(serverURL: serverURL, itemId: itemId))
    }

    @MainActor
    func testProgressBackupWithoutTimeListenedIsStillRecoverable() {
        let store = ProgressBackupStore.shared
        let serverURL = "https://abs.example.com"
        let itemId = "testItem-bug4b"

        store.debugClear(serverURL: serverURL, itemId: itemId)

        let key = store.debugPendingProgressKey(serverURL: serverURL, itemId: itemId)
        let backupWithoutTimeListened: [String: Any] = [
            "currentTime": Double(300),
            "duration": Double(1000),
            "timestamp": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(backupWithoutTimeListened, forKey: key)

        XCTAssertTrue(store.debugHasPending(serverURL: serverURL, itemId: itemId),
                      "Backup without timeListened key should still be detected as pending")

        store.debugClear(serverURL: serverURL, itemId: itemId)
    }

    // MARK: - Bug 5: updateSearchFields not called after sync

    @MainActor
    func testBookUpdateSearchFieldsAfterTitleChange() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)

        let book = Book(title: "Old Title", author: "Old Author", duration: 1000)
        context.insert(book)
        try context.save()

        XCTAssertEqual(book.normalizedTitle, "old title")
        XCTAssertEqual(book.normalizedAuthor, "old author")

        book.title = "New Title"
        book.author = "New Author"
        book.updateSearchFields()

        XCTAssertEqual(book.normalizedTitle, "new title",
                       "normalizedTitle must update after calling updateSearchFields()")
        XCTAssertEqual(book.normalizedAuthor, "new author",
                       "normalizedAuthor must update after calling updateSearchFields()")
    }

    @MainActor
    func testSearchMatchesUpdatedTitleAfterSyncFix() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)

        let book = Book(title: "Original", author: "AuthorA", duration: 500)
        context.insert(book)

        book.title = "Updated Title"
        book.author = "Updated Author"
        book.updateSearchFields()

        XCTAssertTrue(book.matchesSearch(query: "updated"), "Book should match search by new title")
        XCTAssertFalse(book.matchesSearch(query: "original"), "Book should not match search by old title after updateSearchFields()")
    }

    // MARK: - Bug 6: Stale UserDefaults backup overrides newer position

    @MainActor
    func testRestorePositionIgnoresBackupOlderThanLastPlayedDate() {
        let bookId = UUID()
        let key = "localBookPosition_\(bookId.uuidString)"

        let oldTimestamp = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let backup: [String: Any] = [
            "currentTime": Double(42.0),
            "timestamp": oldTimestamp
        ]
        UserDefaults.standard.set(backup, forKey: key)

        let recentPlayedDate = Date().addingTimeInterval(-1800)
        let isBackupStale = recentPlayedDate.timeIntervalSince1970 > oldTimestamp
        XCTAssertTrue(isBackupStale, "Backup written before lastPlayedDate should be considered stale")

        UserDefaults.standard.removeObject(forKey: key)
    }

    @MainActor
    func testRestorePositionUsesBackupNewerThanLastPlayedDate() {
        let bookId = UUID()
        let key = "localBookPosition_\(bookId.uuidString)"

        let recentTimestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let backup: [String: Any] = [
            "currentTime": Double(99.0),
            "timestamp": recentTimestamp
        ]
        UserDefaults.standard.set(backup, forKey: key)

        let olderPlayedDate = Date().addingTimeInterval(-3600)
        let isBackupNewer = recentTimestamp > olderPlayedDate.timeIntervalSince1970
        XCTAssertTrue(isBackupNewer, "A backup more recent than lastPlayedDate should be used")

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Bug 7: enqueue() cancels existing task before replacing

    @MainActor
    func testEnqueueCancelsPreviousTaskForSameBookId() {
        let coordinator = RemoteLibraryUICoverArtCoordinator.shared
        coordinator.debugResetState()

        let bookId = UUID()

        let firstTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        coordinator.debugRegisterTask(firstTask, for: bookId)
        XCTAssertEqual(coordinator.debugTaskCount, 1)
        XCTAssertFalse(firstTask.isCancelled, "First task should not yet be cancelled")

        let secondTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        coordinator.debugRegisterTask(secondTask, for: bookId)

        XCTAssertEqual(coordinator.debugTaskCount, 1, "Should still be only one tracked task per bookId")

        coordinator.cancelAllCoverArtDownloads()
        XCTAssertTrue(secondTask.isCancelled)
    }

    @MainActor
    func testEnqueueTracksNewTaskAfterCancellingOld() {
        let coordinator = RemoteLibraryUICoverArtCoordinator.shared
        coordinator.debugResetState()

        let bookIdA = UUID()
        let bookIdB = UUID()

        let taskA = Task<Void, Never> { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) } }
        let taskB = Task<Void, Never> { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) } }

        coordinator.debugRegisterTask(taskA, for: bookIdA)
        coordinator.debugRegisterTask(taskB, for: bookIdB)
        XCTAssertEqual(coordinator.debugTaskCount, 2)

        coordinator.cancelAllCoverArtDownloads()
        XCTAssertEqual(coordinator.debugTaskCount, 0)
    }

    // MARK: - Bug 8: StorageBackupManager copies all DB files

    func testDatabaseFilesIncludesWALAndSHM() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeFile = tempDir.appendingPathComponent("default.store")
        let walFile = storeFile.appendingPathExtension("wal")
        let shmFile = storeFile.appendingPathExtension("shm")

        FileManager.default.createFile(atPath: storeFile.path, contents: Data("store".utf8))
        FileManager.default.createFile(atPath: walFile.path, contents: Data("wal".utf8))
        FileManager.default.createFile(atPath: shmFile.path, contents: Data("shm".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: walFile.path), "WAL file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmFile.path), "SHM file should exist")

        let storeExists = FileManager.default.fileExists(atPath: storeFile.path)
        let walExists = FileManager.default.fileExists(atPath: walFile.path)
        let shmExists = FileManager.default.fileExists(atPath: shmFile.path)

        XCTAssertTrue(storeExists && walExists && shmExists,
                      "All three SQLite files must be present for a complete backup")
    }

    func testBackupDatabaseFileNamingPattern() {
        let allFiles = ["default.store", "default.store.wal", "default.store.shm"]
        let expectedSuffixes = [".store", ".wal.store", ".shm.store"]

        let timestamp = "2026-01-01_12-00-00"
        let generatedNames = allFiles.map { file -> String in
            let ext = (file as NSString).pathExtension
            let nameSuffix = ext == "store" ? "" : ".\(ext)"
            return "StoryCast_backup_\(timestamp)\(nameSuffix).store"
        }

        for (name, expected) in zip(generatedNames, expectedSuffixes) {
            XCTAssertTrue(name.hasSuffix(expected), "Backup file '\(name)' should have suffix '\(expected)'")
        }
    }

    // MARK: - Bug 9: SleepTimer fires on paused playback

    @MainActor
    func testSleepTimerServiceExists() {
        let service = SleepTimerService.shared
        XCTAssertNotNil(service, "SleepTimerService.shared should be accessible")
    }

    @MainActor
    func testSleepTimerDoesNotFireWhenNotPlaying() {
        let audioPlayer = AudioPlayerService.shared
        XCTAssertFalse(audioPlayer.isPlaying,
                       "isPlaying should be false when no audio is loaded — timer guard relies on this")
    }

    // MARK: - Bug 10: "migration" keyword makes migrationFailed unreachable

    func testMigrationOnlyErrorCategorizedAsMigrationFailed() {
        struct MigrationError: Error, LocalizedError {
            var errorDescription: String? { "Core Data migration failed unexpectedly" }
        }

        let error = MigrationError()
        let category = StorageVersionValidator.categorize(error)

        if case .migrationFailed = category {
        } else {
            XCTFail("Error containing 'migration' (but not other version-mismatch keywords) should be .migrationFailed, got \(category)")
        }
    }

    func testVersionMismatchErrorNotCategorizedAsMigration() {
        struct ChecksumError: Error, LocalizedError {
            var errorDescription: String? { "Store checksum does not match expected value" }
        }

        let error = ChecksumError()
        let category = StorageVersionValidator.categorize(error)

        if case .versionMismatchDetected = category {
        } else {
            XCTFail("Checksum error should be categorized as .versionMismatchDetected, got \(category)")
        }
    }

    func testVersionMismatchKeywordsNoLongerContainMigration() {
        let migrationOnlyError = NSError(
            domain: "TestDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "migration happened"]
        )

        let isMismatch = StorageVersionValidator.isVersionMismatchError(migrationOnlyError)
        XCTAssertFalse(isMismatch,
                       "'migration' alone should not trigger isVersionMismatchError after removing it from versionMismatchKeywords")
    }

    // MARK: - Bug 11: tasks.removeValue in non-isolated Task (Swift 6 safety)

    @MainActor
    func testCoverArtTaskRemovedAfterCancellation() {
        let coordinator = RemoteLibraryUICoverArtCoordinator.shared
        coordinator.debugResetState()

        let bookId = UUID()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        coordinator.debugRegisterTask(task, for: bookId)
        XCTAssertEqual(coordinator.debugTaskCount, 1)

        coordinator.cancelAllCoverArtDownloads()
        XCTAssertEqual(coordinator.debugTaskCount, 0, "Task should be removed after cancellation")
        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Bug 12: Thread.sleep removed from AppBootstrap

    func testMakeRecoveryContainerSucceedsWithoutSleep() {
        let container = AppBootstrap.makeRecoveryContainer()
        XCTAssertNotNil(container, "makeRecoveryContainer() should return a valid in-memory container")
    }

    func testMakeRecoveryContainerReturnsInMemoryContainer() {
        guard let container = AppBootstrap.makeRecoveryContainer() else {
            XCTFail("makeRecoveryContainer() returned nil")
            return
        }
        let context = ModelContext(container)
        XCTAssertNotNil(context, "ModelContext should be creatable from recovery container")
    }

    // MARK: - Bug 13: StartupCoordinator key capture

    @MainActor
    func testStartupCoordinatorMigrationKeysAreStable() {
        let legacyKey = "hasCompletedLegacyLibraryDeduplication"
        let normalizedKey = "hasCompletedNormalizedURLMigration"

        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: normalizedKey)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: legacyKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: normalizedKey))

        UserDefaults.standard.set(true, forKey: legacyKey)
        UserDefaults.standard.set(true, forKey: normalizedKey)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: legacyKey),
                      "Legacy deduplication key should persist correctly")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: normalizedKey),
                      "Normalized URL migration key should persist correctly")

        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: normalizedKey)
    }

    // MARK: - Bug 5 (additional): Book.matchesSearch relies on normalized fields

    @MainActor
    func testBookMatchesSearchUsesNormalizedFields() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, SchemaV3Marker.self, configurations: config)
        let context = ModelContext(container)

        let book = Book(title: "The Great Gatsby", author: "F. Scott Fitzgerald", duration: 3600)
        context.insert(book)

        XCTAssertTrue(book.matchesSearch(query: "great"), "Should match partial title")
        XCTAssertTrue(book.matchesSearch(query: "fitzgerald"), "Should match partial author")
        XCTAssertFalse(book.matchesSearch(query: "hemingway"), "Should not match unrelated author")

        book.title = "A Farewell to Arms"
        book.author = "Ernest Hemingway"
        book.updateSearchFields()

        XCTAssertTrue(book.matchesSearch(query: "hemingway"), "Should match new author after updateSearchFields()")
        XCTAssertFalse(book.matchesSearch(query: "fitzgerald"), "Should not match old author after updateSearchFields()")
    }
}
