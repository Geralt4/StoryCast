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
        
        do {
            try FileManager.default.copyItem(at: databaseURL, to: backupURL)
            AppLogger.app.info("Database backed up to: \(backupURL.path)")
            return backupURL
        } catch {
            AppLogger.app.error("Failed to backup database: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Lists all available backups, sorted by date (newest first)
    static func listBackups() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return []
        }
        
        let backups = contents.filter { $0.pathExtension == "store" }
        
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
}