import Foundation
import os

/// Manages database backups before recovery operations
nonisolated enum StorageBackupManager {
    
    // MARK: - Constants
    
    private static let backupDirectoryName = "Backups"
    private static let maxBackupCount = 3
    private static let databaseFileName = "default.store"
    
    // MARK: - Database Location
    
    /// Returns the URL of the SwiftData database file
    /// SwiftData stores at: Application Support/default.store
    static var databaseURL: URL? {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        
        let storeURL = appSupportURL.appendingPathComponent(databaseFileName)
        return FileManager.default.fileExists(atPath: storeURL.path) ? storeURL : nil
    }
    
    /// Returns all database-related files (main store, WAL, SHM)
    static var databaseFiles: [URL] {
        guard let mainStore = databaseURL else { return [] }
        return [
            mainStore,
            mainStore.appendingPathExtension("wal"),
            mainStore.appendingPathExtension("shm")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    
    /// Deletes all database files
    /// - Returns: True if all files were deleted successfully
    @discardableResult
    static func deleteDatabaseFiles() -> Bool {
        var allSucceeded = true
        for fileURL in databaseFiles {
            do {
                try FileManager.default.removeItem(at: fileURL)
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
    /// - Returns: URL of the backup file, or nil if no database exists or backup failed
    static func backupDatabase() -> URL? {
        guard let databaseURL = databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            AppLogger.app.info("No database to backup")
            return nil
        }
        
        cleanupOldBackups()
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let backupFileName = "StoryCast_backup_\(timestamp).store"
        let backupURL = backupDirectoryURL.appendingPathComponent(backupFileName)

        var anySucceeded = false
        for sourceFile in databaseFiles {
            let baseName: String
            if sourceFile.pathExtension == "store" {
                baseName = "StoryCast_backup_\(timestamp).store"
            } else {
                // WAL/SHM files: preserve the full extension chain (e.g., .store.wal)
                baseName = "StoryCast_backup_\(timestamp).store.\(sourceFile.pathExtension)"
            }
            let destURL = backupDirectoryURL.appendingPathComponent(baseName)
            do {
                try FileManager.default.copyItem(at: sourceFile, to: destURL)
                if sourceFile == databaseURL { anySucceeded = true }
            } catch {
                AppLogger.app.error("Failed to backup \(sourceFile.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if anySucceeded {
            AppLogger.app.info("Database backed up to: \(backupURL.path)")
            return backupURL
        }
        return nil
    }
    
    /// Lists all available backups, sorted by date (newest first)
    static func listBackups() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return []
        }
        
        // Filter to only main store files (exclude .wal, .shm backups)
        let backups = contents.filter { url in
            url.pathExtension == "store" && url.lastPathComponent.hasSuffix(".store") && !url.lastPathComponent.contains(".store.")
        }
        
        return backups.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }
    }
    
    /// Removes old backups, keeping only the most recent `maxBackupCount` backups
    static func cleanupOldBackups() {
        let backups = listBackups()
        let backupsToDelete = backups.dropFirst(maxBackupCount)
        
        for backupURL in backupsToDelete {
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                AppLogger.app.warning("Failed to delete old backup: \(error.localizedDescription)")
            }
        }
    }
    
    /// Returns the size of a backup in human-readable format
    static func formattedSize(of backupURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: backupURL.path),
              let fileSize = attributes[.size] as? Int64 else {
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
        
        let date = (try? backupURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return dateFormatter.string(from: date)
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