import Foundation
import XCTest
@testable import StoryCast

nonisolated final class StorageBackupManagerTests: XCTestCase {
    func testDatabaseFileURLsUseCanonicalSQLiteSidecarNames() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))
        try Data("wrong".utf8).write(to: storeURL.appendingPathExtension("wal"))

        XCTAssertEqual(
            StorageBackupManager.databaseFileURLs(for: storeURL).map(\.lastPathComponent),
            ["default.store", "default.store-wal", "default.store-shm"]
        )
    }

    func testCompleteBackupPublishesVerifiedBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let storeURL = sourceDirectory.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))

        let backupURL = try StorageBackupManager.createBackup(
            mainStoreURL: storeURL,
            backupDirectoryURL: backupDirectory,
            date: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(backupURL.pathExtension, "storycastbackup")
        XCTAssertEqual(StorageBackupManager.listBackups(in: backupDirectory), [backupURL])
        let backedUpStore = try XCTUnwrap(StorageBackupManager.backupStoreURL(for: backupURL))
        XCTAssertEqual(try Data(contentsOf: backedUpStore), Data("store".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: backedUpStore.path + "-wal")),
            Data("wal".utf8)
        )
        XCTAssertNotEqual(StorageBackupManager.formattedSize(of: backupURL), "Unknown size")
    }

    func testSidecarCopyFailureDoesNotPublishPartialBackupOrRotateGoodBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let storeURL = sourceDirectory.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        let goodBackup = try StorageBackupManager.createBackup(
            mainStoreURL: storeURL,
            backupDirectoryURL: backupDirectory,
            date: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertThrowsError(try StorageBackupManager.createBackup(
            mainStoreURL: storeURL,
            backupDirectoryURL: backupDirectory,
            date: Date(timeIntervalSince1970: 2_000),
            copyItem: { source, destination in
                if source.lastPathComponent.hasSuffix("-wal") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        ))

        XCTAssertEqual(StorageBackupManager.listBackups(in: backupDirectory), [goodBackup])
        let contents = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".partial-") })
    }

    func testDeleteRemovesOrphanedSidecarsWhenMainStoreIsMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        XCTAssertTrue(StorageBackupManager.deleteDatabaseFiles(mainStoreURL: storeURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testCleanupDeletesWholeBackupBundles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let storeURL = sourceDirectory.appendingPathComponent("default.store")
        try Data("store".utf8).write(to: storeURL)
        var backups: [URL] = []
        for timestamp in [1_000.0, 2_000.0, 3_000.0] {
            backups.append(try StorageBackupManager.createBackup(
                mainStoreURL: storeURL,
                backupDirectoryURL: backupDirectory,
                date: Date(timeIntervalSince1970: timestamp)
            ))
        }

        StorageBackupManager.cleanupOldBackups(in: backupDirectory, keeping: 1)

        XCTAssertEqual(StorageBackupManager.listBackups(in: backupDirectory), [backups[2]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups[1].path))
    }

    func testLegacyDottedSidecarsMaterializeWithCanonicalNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Working", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let legacyStore = backupDirectory.appendingPathComponent("StoryCast_backup_2026-01-01_12-00-00.store")
        try Data("store".utf8).write(to: legacyStore)
        try Data("wal".utf8).write(to: legacyStore.appendingPathExtension("wal"))
        try Data("shm".utf8).write(to: legacyStore.appendingPathExtension("shm"))

        XCTAssertEqual(StorageBackupManager.listBackups(in: backupDirectory), [legacyStore])
        let workingStore = try StorageBackupManager.materializeBackup(
            legacyStore,
            in: workingDirectory
        )

        XCTAssertEqual(workingStore.lastPathComponent, "default.store")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: workingStore.path + "-wal")),
            Data("wal".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: workingStore.path + "-shm")),
            Data("shm".utf8)
        )
    }

    func testIncompleteBundleIsNotListed() throws {
        let backupDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let partialBundle = backupDirectory
            .appendingPathComponent("StoryCast_backup_incomplete")
            .appendingPathExtension("storycastbackup")
        try FileManager.default.createDirectory(at: partialBundle, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: partialBundle.appendingPathComponent("default.store"))

        XCTAssertTrue(StorageBackupManager.listBackups(in: backupDirectory).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
