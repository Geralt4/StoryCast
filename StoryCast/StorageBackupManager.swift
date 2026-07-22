import Foundation
import os

nonisolated struct StorageBackupManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let storeFileName: String
    let includedFileNames: [String]
    let byteCounts: [String: Int64]
}

nonisolated enum StorageBackupError: LocalizedError {
    case mainStoreMissing
    case verificationFailed(fileName: String)

    var errorDescription: String? {
        switch self {
        case .mainStoreMissing:
            return "The database store does not exist."
        case .verificationFailed(let fileName):
            return "The backup copy of \(fileName) could not be verified."
        }
    }
}

/// Manages database backups before recovery operations
nonisolated enum StorageBackupManager {
    
    // MARK: - Constants
    
    private static let backupDirectoryName = "Backups"
    private static let maxBackupCount = 3
    private static let databaseFileName = "default.store"
    private static let backupBundleExtension = "storycastbackup"
    private static let manifestFileName = "manifest.json"
    
    // MARK: - Database Location
    
    /// Returns the URL of the SwiftData database file
    /// SwiftData stores at: Application Support/default.store
    static var databaseURL: URL? {
        guard let storeURL = configuredDatabaseURL else { return nil }
        return FileManager.default.fileExists(atPath: storeURL.path) ? storeURL : nil
    }

    private static var configuredDatabaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(databaseFileName)
    }
    
    /// Returns all database-related files (main store, WAL, SHM)
    static var databaseFiles: [URL] {
        guard let mainStore = configuredDatabaseURL else { return [] }
        return databaseFileURLs(for: mainStore)
    }

    static func databaseFileURLs(
        for mainStoreURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        canonicalDatabaseFileURLs(for: mainStoreURL).filter {
            fileManager.fileExists(atPath: $0.path)
        }
    }
    
    /// Deletes all database files
    /// - Returns: True if all files were deleted successfully
    @discardableResult
    static func deleteDatabaseFiles() -> Bool {
        guard let mainStoreURL = configuredDatabaseURL else { return false }
        return deleteDatabaseFiles(mainStoreURL: mainStoreURL)
    }

    @discardableResult
    static func deleteDatabaseFiles(
        mainStoreURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var allSucceeded = true
        for fileURL in canonicalDatabaseFileURLs(for: mainStoreURL)
        where fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                AppLogger.app.error("Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }
    
    // MARK: - Backup Directory
    
    /// Returns the URL for the backup directory, creating it if necessary
    static var backupDirectoryURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let backupURL = appSupportURL.appendingPathComponent("StoryCast", isDirectory: true)
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.createDirectory(
                at: backupURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        return backupURL
    }
    
    // MARK: - Backup Operations
    
    /// Creates a backup of the current database
    /// - Returns: URL of the complete backup bundle, or nil if no database exists or backup failed
    static func backupDatabase() -> URL? {
        guard let databaseURL else {
            AppLogger.app.info("No database to backup")
            return nil
        }

        do {
            let backupURL = try createBackup(
                mainStoreURL: databaseURL,
                backupDirectoryURL: backupDirectoryURL
            )
            AppLogger.app.info("Database backed up to: \(backupURL.path)")
            return backupURL
        } catch {
            AppLogger.app.error("Database backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func createBackup(
        mainStoreURL: URL,
        backupDirectoryURL: URL,
        date: Date = Date(),
        fileManager: FileManager = .default,
        copyItem: ((_ source: URL, _ destination: URL) throws -> Void)? = nil
    ) throws -> URL {
        guard fileManager.fileExists(atPath: mainStoreURL.path) else {
            throw StorageBackupError.mainStoreMissing
        }

        try fileManager.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true
        )

        let sourceFiles = databaseFileURLs(for: mainStoreURL, fileManager: fileManager)
        let sourceSizes = try Dictionary(uniqueKeysWithValues: sourceFiles.map { source in
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return (source.lastPathComponent, size)
        })

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: date)
        let uniqueSuffix = UUID().uuidString.prefix(8).lowercased()
        let finalPathURL = backupDirectoryURL
            .appendingPathComponent("StoryCast_backup_\(timestamp)_\(uniqueSuffix)")
            .appendingPathExtension(backupBundleExtension)
        let finalURL = URL(fileURLWithPath: finalPathURL.path, isDirectory: true)
        let stagingURL = backupDirectoryURL
            .appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let performCopy = copyItem ?? { source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        for sourceFile in sourceFiles {
            let destination = stagingURL.appendingPathComponent(sourceFile.lastPathComponent)
            try performCopy(sourceFile, destination)
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            let copiedSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard copiedSize == sourceSizes[sourceFile.lastPathComponent] else {
                throw StorageBackupError.verificationFailed(fileName: sourceFile.lastPathComponent)
            }
        }

        let manifest = StorageBackupManifest(
            version: StorageBackupManifest.currentVersion,
            createdAt: date,
            storeFileName: mainStoreURL.lastPathComponent,
            includedFileNames: sourceFiles.map(\.lastPathComponent),
            byteCounts: sourceSizes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: stagingURL.appendingPathComponent(manifestFileName),
            options: .atomic
        )

        try fileManager.moveItem(at: stagingURL, to: finalURL)
        shouldRemoveStaging = false
        cleanupOldBackups(in: backupDirectoryURL, keeping: maxBackupCount, fileManager: fileManager)
        return finalURL
    }
    
    /// Lists all available backups, sorted by date (newest first)
    static func listBackups() -> [URL] {
        listBackups(in: backupDirectoryURL)
    }

    static func listBackups(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        ) else {
            return []
        }

        let backups = contents.filter { url in
            if url.pathExtension == backupBundleExtension {
                return backupManifest(at: url, fileManager: fileManager) != nil &&
                    backupStoreURL(for: url, fileManager: fileManager) != nil
            }
            return isLegacyMainStoreBackup(url)
        }

        return backups.sorted { url1, url2 in
            let date1 = backupDate(for: url1, fileManager: fileManager)
            let date2 = backupDate(for: url2, fileManager: fileManager)
            return date1 > date2
        }
    }
    
    /// Removes old backups, keeping only the most recent `maxBackupCount` backups
    static func cleanupOldBackups() {
        cleanupOldBackups(in: backupDirectoryURL, keeping: maxBackupCount)
    }

    static func cleanupOldBackups(
        in directoryURL: URL,
        keeping maximumCount: Int,
        fileManager: FileManager = .default
    ) {
        let backupsToDelete = listBackups(in: directoryURL, fileManager: fileManager)
            .dropFirst(max(0, maximumCount))

        for backupURL in backupsToDelete {
            do {
                try removeBackup(at: backupURL, fileManager: fileManager)
            } catch {
                AppLogger.app.warning("Failed to delete old backup: \(error.localizedDescription)")
            }
        }
    }
    
    /// Returns the size of a backup in human-readable format
    static func formattedSize(of backupURL: URL) -> String {
        guard let fileSize = backupByteCount(at: backupURL) else {
            return "Unknown size"
        }
        
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: fileSize)
    }
    
    /// Returns formatted date for a backup
    static func formattedDate(of backupURL: URL) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        let date = backupDate(for: backupURL)
        return dateFormatter.string(from: date)
    }

    /// Resolves the SQLite main-store URL for a complete bundle or legacy flat backup.
    static func backupStoreURL(
        for backupURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        if backupURL.pathExtension == backupBundleExtension {
            guard let manifest = backupManifest(at: backupURL, fileManager: fileManager) else { return nil }
            let storeURL = backupURL.appendingPathComponent(manifest.storeFileName)
            return fileManager.fileExists(atPath: storeURL.path) ? storeURL : nil
        }
        return isLegacyMainStoreBackup(backupURL) && fileManager.fileExists(atPath: backupURL.path)
            ? backupURL
            : nil
    }

    /// Copies a backup into a writable working directory without mutating the backup itself.
    static func materializeBackup(
        _ backupURL: URL,
        in destinationDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let sourceStoreURL = backupStoreURL(for: backupURL, fileManager: fileManager) else {
            throw StorageBackupError.mainStoreMissing
        }
        try fileManager.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )

        let destinationStoreURL = destinationDirectoryURL.appendingPathComponent(databaseFileName)
        try fileManager.copyItem(at: sourceStoreURL, to: destinationStoreURL)
        for suffix in ["wal", "shm"] {
            guard let sourceSidecar = backupSidecarURL(
                for: sourceStoreURL,
                suffix: suffix,
                fileManager: fileManager
            ) else {
                continue
            }
            let destinationSidecar = URL(fileURLWithPath: destinationStoreURL.path + "-\(suffix)")
            try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
        }
        return destinationStoreURL
    }

    private static func canonicalDatabaseFileURLs(for mainStoreURL: URL) -> [URL] {
        [
            mainStoreURL,
            URL(fileURLWithPath: mainStoreURL.path + "-wal"),
            URL(fileURLWithPath: mainStoreURL.path + "-shm")
        ]
    }

    private static func backupManifest(
        at backupURL: URL,
        fileManager: FileManager
    ) -> StorageBackupManifest? {
        let manifestURL = backupURL.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(StorageBackupManifest.self, from: data),
              manifest.version == StorageBackupManifest.currentVersion,
              manifest.includedFileNames.contains(manifest.storeFileName) else {
            return nil
        }

        for fileName in manifest.includedFileNames {
            guard fileName == (fileName as NSString).lastPathComponent,
                  let expectedSize = manifest.byteCounts[fileName] else {
                return nil
            }
            let fileURL = backupURL.appendingPathComponent(fileName)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
                return nil
            }
        }
        return manifest
    }

    private static func backupDate(
        for backupURL: URL,
        fileManager: FileManager = .default
    ) -> Date {
        if let manifest = backupManifest(at: backupURL, fileManager: fileManager) {
            return manifest.createdAt
        }
        return (try? backupURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date.distantPast
    }

    private static func isLegacyMainStoreBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard name.hasPrefix("storycast_backup_"), name.hasSuffix(".store") else { return false }
        return !name.hasSuffix(".wal.store") &&
            !name.hasSuffix(".shm.store") &&
            !name.contains(".store.")
    }

    private static func backupSidecarURL(
        for mainStoreURL: URL,
        suffix: String,
        fileManager: FileManager
    ) -> URL? {
        let baseURL = mainStoreURL.deletingPathExtension()
        let candidates = [
            URL(fileURLWithPath: mainStoreURL.path + "-\(suffix)"),
            mainStoreURL.appendingPathExtension(suffix),
            baseURL.appendingPathExtension(suffix).appendingPathExtension("store")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func removeBackup(at backupURL: URL, fileManager: FileManager) throws {
        if backupURL.pathExtension == backupBundleExtension {
            try fileManager.removeItem(at: backupURL)
            return
        }

        let baseURL = backupURL.deletingPathExtension()
        let candidates = [
            backupURL,
            URL(fileURLWithPath: backupURL.path + "-wal"),
            URL(fileURLWithPath: backupURL.path + "-shm"),
            backupURL.appendingPathExtension("wal"),
            backupURL.appendingPathExtension("shm"),
            baseURL.appendingPathExtension("wal").appendingPathExtension("store"),
            baseURL.appendingPathExtension("shm").appendingPathExtension("store")
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private static func backupByteCount(
        at backupURL: URL,
        fileManager: FileManager = .default
    ) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: backupURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: backupURL.path)
            return (attributes?[.size] as? NSNumber)?.int64Value
        }

        guard let enumerator = fileManager.enumerator(
            at: backupURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return nil
        }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
    
    // MARK: - Cover Art Backup
    
    /// Backs up cover art to the backup directory
    /// Cover art is small (~50KB) and critical for UX, so it's worth backing up
    /// - Returns: Number of cover art files backed up, or nil if operation failed
    static func backupCoverArt() -> Int? {
        let coverArtURLs = [
            documentsBackedDirectoryURL(named: "CoverArt"),
            applicationSupportBackedDirectoryURL(named: "RemoteCoverArt")
        ]
        
        var backedUpCount = 0
        
        for coverArtDir in coverArtURLs {
            guard FileManager.default.fileExists(atPath: coverArtDir.path) else { continue }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: coverArtDir, includingPropertiesForKeys: nil)
                
                for file in files where file.pathExtension.lowercased() == "jpg" || file.pathExtension.lowercased() == "jpeg" || file.pathExtension.lowercased() == "png" {
                    let backupFileName = "coverart_\(file.lastPathComponent)"
                    let destURL = backupDirectoryURL.appendingPathComponent(backupFileName)
                    
                    do {
                        try FileManager.default.copyItem(at: file, to: destURL)
                        backedUpCount += 1
                    } catch {
                        AppLogger.app.warning("Failed to backup cover art \(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } catch {
                AppLogger.app.error("Failed to list cover art directory \(coverArtDir.path): \(error.localizedDescription)")
                return nil
            }
        }
        
        AppLogger.app.info("Backed up \(backedUpCount) cover art files")
        return backedUpCount
    }
    
    /// Restores cover art from the backup directory
    /// - Returns: Number of cover art files restored, or nil if operation failed
    static func restoreCoverArt() -> Int? {
        var restoredCount = 0
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: backupDirectoryURL, includingPropertiesForKeys: nil) else {
            AppLogger.app.info("No backup directory contents to restore cover art from")
            return nil
        }
        
        let coverArtFiles = contents.filter { $0.lastPathComponent.hasPrefix("coverart_") }
        
        for backupFile in coverArtFiles {
            // Determine the correct destination based on whether it's remote or local cover art
            let fileName = String(backupFile.lastPathComponent.dropFirst("coverart_".count))
            let isRemote = fileName.contains("_remote_") || backupFile.lastPathComponent.contains("_remote_")
            
            let destDir: URL
            if isRemote {
                destDir = applicationSupportBackedDirectoryURL(named: "RemoteCoverArt")
            } else {
                destDir = documentsBackedDirectoryURL(named: "CoverArt")
            }
            
            // Create destination directory if needed
            if !FileManager.default.fileExists(atPath: destDir.path) {
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            
            let destURL = destDir.appendingPathComponent(fileName)
            
            // Skip if destination already exists (don't overwrite newer files)
            if FileManager.default.fileExists(atPath: destURL.path) {
                continue
            }
            
            do {
                try FileManager.default.copyItem(at: backupFile, to: destURL)
                restoredCount += 1
            } catch {
                AppLogger.app.warning("Failed to restore cover art \(backupFile.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        AppLogger.app.info("Restored \(restoredCount) cover art files")
        return restoredCount
    }
    
    /// Lists all backed up cover art files
    static func listBackedUpCoverArt() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: backupDirectoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return contents.filter { $0.lastPathComponent.hasPrefix("coverart_") }
    }
    
    // MARK: - Helper Methods
    
    private static func documentsBackedDirectoryURL(named folderName: String) -> URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(folderName)
        }
        return documentsURL.appendingPathComponent(folderName)
    }
    
    private static func applicationSupportBackedDirectoryURL(named folderName: String) -> URL {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(folderName)
        }
        return appSupportURL.appendingPathComponent(folderName)
    }
}
