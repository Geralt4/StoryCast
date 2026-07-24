import Foundation
import Security
import os
import SwiftData
#if os(iOS)
import UIKit
#endif

private struct RemoteBookMigrationInfo: Sendable {
    let isDownloaded: Bool
    let localCachePath: String?
    let coverArtFileName: String?
}

private struct RemoteAssetMigrationSnapshot: Sendable {
    let remoteBooks: [RemoteBookMigrationInfo]
    let localAudioFileNames: Set<String>
    let localCoverArtFileNames: Set<String>
}

actor StorageManager {
    /// Canonical folder name for locally imported audio.
    nonisolated static let libraryFolderName = "StoryCastLibrary"

    /// Canonical folder name for locally imported cover art.
    nonisolated static let coverArtFolderName = "CoverArt"

    enum CoverArtLocation {
        case localLibrary
        case remoteCache
    }

    private enum ManagedDirectory: CaseIterable {
        case library
        case coverArt
        case remoteAudioCache
        case remoteCoverArt

        var folderName: String {
            switch self {
            case .library:
                return "StoryCastLibrary"
            case .coverArt:
                return "CoverArt"
            case .remoteAudioCache:
                return "RemoteAudioCache"
            case .remoteCoverArt:
                return "RemoteCoverArt"
            }
        }

        var usesApplicationSupport: Bool {
            switch self {
            case .remoteAudioCache, .remoteCoverArt:
                return true
            case .library, .coverArt:
                return false
            }
        }

    }

    static let shared = StorageManager()
    
    private init() {}

    #if os(iOS)
    nonisolated(unsafe) private static let fileProtectionAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    #endif

    // MARK: - Path Resolution

    nonisolated var storyCastLibraryURL: URL {
        directoryURL(for: .library)
    }

    nonisolated var coverArtDirectoryURL: URL {
        directoryURL(for: .coverArt)
    }

    nonisolated var remoteAudioCacheDirectoryURL: URL {
        directoryURL(for: .remoteAudioCache)
    }

    nonisolated var remoteCoverArtDirectoryURL: URL {
        directoryURL(for: .remoteCoverArt)
    }

    nonisolated func remoteAudioCacheURL(for fileName: String) -> URL {
        remoteAudioCacheDirectoryURL.appendingPathComponent(fileName)
    }

    nonisolated func resolvedRemoteAudioCacheURL(for fileName: String) -> URL {
        let preferredURL = remoteAudioCacheURL(for: fileName)
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let legacyURL = storyCastLibraryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }

        return preferredURL
    }

    nonisolated func coverArtURL(for fileName: String, isRemote: Bool) -> URL {
        let preferredURL = (isRemote ? remoteCoverArtDirectoryURL : coverArtDirectoryURL)
            .appendingPathComponent(fileName)

        if !isRemote || FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let legacyURL = coverArtDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }

        return preferredURL
    }

    nonisolated func coverArtURL(for fileName: String) -> URL {
        coverArtDirectoryURL.appendingPathComponent(fileName)
    }

    // MARK: - Directory Setup

    func setupStoryCastLibraryDirectory() throws {
        try ensureDirectoryExists(for: .library)
    }

    func setupCoverArtDirectory() throws {
        try ensureDirectoryExists(for: .coverArt)
    }

    func setupRemoteAudioCacheDirectory() throws {
        try ensureDirectoryExists(for: .remoteAudioCache)
    }

    func setupRemoteCoverArtDirectory() throws {
        try ensureDirectoryExists(for: .remoteCoverArt)
    }

    // MARK: - File Operations

    func saveCoverArt(_ data: Data, for bookId: UUID, location: CoverArtLocation = .localLibrary) throws -> String? {
        guard let dataToWrite = normalizedCoverArtData(from: data) else {
            return nil
        }

        let fileName = "\(bookId.uuidString).jpg"
        let isRemote = location == .remoteCache
        let destinationURL = coverArtURL(for: fileName, isRemote: isRemote)

        try ensureCoverArtDirectoryExists(for: location)
        try writeData(dataToWrite, to: destinationURL)
        return fileName
    }

    func deleteCoverArt(fileName: String, isRemote: Bool = false) {
        guard isSafeManagedFileName(fileName) else {
            AppLogger.storage.warning("Skipped unsafe cover art deletion path: \(fileName)")
            return
        }

        // Do not delete from the legacy fallback root here. A matching name can
        // legitimately belong to a book in the other library namespace.
        let directoryURL = isRemote ? remoteCoverArtDirectoryURL : coverArtDirectoryURL
        removeFiles(at: [directoryURL.appendingPathComponent(fileName)], errorMessage: "Error deleting cover art")
    }

    func deleteRemoteAudioCache(fileName: String) {
        guard isSafeManagedFileName(fileName) else {
            AppLogger.storage.warning("Skipped unsafe remote audio deletion path: \(fileName)")
            return
        }

        // Local imported audio may share the old fallback filename, so only the
        // remote cache owns this direct-deletion operation.
        removeFiles(at: [remoteAudioCacheURL(for: fileName)])
    }

    func copyFileToStoryCastLibraryDirectory(from sourceURL: URL, withName name: String) throws -> URL {
        let destinationURL = try preparedLibraryDestinationURL(for: name)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try applyProtectionIfNeeded(to: destinationURL)
        return destinationURL
    }

    func moveStagedFileToStoryCastLibraryDirectory(from stagedURL: URL, withName name: String) throws -> URL {
        let destinationURL = try preparedLibraryDestinationURL(for: name)
        try moveOrCopyFile(from: stagedURL, to: destinationURL)
        try applyProtectionIfNeeded(to: destinationURL)
        return destinationURL
    }

    // MARK: - Migrations

    #if os(iOS)
    func migrateFileProtectionIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: StorageDefaults.fileProtectionMigrationKey) else {
            return
        }

        try migrateFileProtectionAcrossManagedDirectories()
        UserDefaults.standard.set(true, forKey: StorageDefaults.fileProtectionMigrationKey)
    }

    func migrateRemoteAssetsIfNeeded(container: ModelContainer) async throws {
        guard !UserDefaults.standard.bool(forKey: StorageDefaults.remoteAssetMigrationKey) else {
            return
        }

        try setupRemoteAudioCacheDirectory()
        try setupRemoteCoverArtDirectory()

        guard let migrationSnapshot = await Self.fetchRemoteBooksForMigration(container: container) else {
            return
        }
        let fileManager = FileManager.default

        for bookInfo in migrationSnapshot.remoteBooks {
            try migrateRemoteAssets(
                isDownloaded: bookInfo.isDownloaded,
                localCachePath: bookInfo.localCachePath,
                coverArtFileName: bookInfo.coverArtFileName,
                localAudioFileNames: migrationSnapshot.localAudioFileNames,
                localCoverArtFileNames: migrationSnapshot.localCoverArtFileNames,
                fileManager: fileManager
            )
        }

        UserDefaults.standard.set(true, forKey: StorageDefaults.remoteAssetMigrationKey)
    }

    @MainActor
    private static func fetchRemoteBooksForMigration(container: ModelContainer) -> RemoteAssetMigrationSnapshot? {
        let context = ModelContext(container)
        do {
            let books = try context.fetch(FetchDescriptor<Book>())
            let remoteBooks = books.filter(\.isRemote).map { book in
                RemoteBookMigrationInfo(
                    isDownloaded: book.isDownloaded,
                    localCachePath: book.localCachePath,
                    coverArtFileName: book.coverArtFileName
                )
            }
            let localBooks = books.filter { !$0.isRemote }
            return RemoteAssetMigrationSnapshot(
                remoteBooks: remoteBooks,
                localAudioFileNames: Set(localBooks.map(\.localFileName)),
                localCoverArtFileNames: Set(localBooks.compactMap(\.coverArtFileName))
            )
        } catch {
            AppLogger.storage.error("Failed to fetch remote books for migration: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func migrateRemoteAssets(
        isDownloaded: Bool,
        localCachePath: String?,
        coverArtFileName: String?,
        localAudioFileNames: Set<String>,
        localCoverArtFileNames: Set<String>,
        fileManager: FileManager
    ) throws {
        if isDownloaded,
           let cachePath = localCachePath,
           !localAudioFileNames.contains(cachePath),
           let legacyURL = managedFileURL(in: storyCastLibraryURL, named: cachePath),
           let privateURL = managedFileURL(in: remoteAudioCacheDirectoryURL, named: cachePath) {
            try migrateFileIfNeeded(from: legacyURL, to: privateURL, fileManager: fileManager)
        }

        if let coverArtFileName,
           !localCoverArtFileNames.contains(coverArtFileName),
           let legacyURL = managedFileURL(in: coverArtDirectoryURL, named: coverArtFileName),
           let privateURL = managedFileURL(in: remoteCoverArtDirectoryURL, named: coverArtFileName) {
            try migrateFileIfNeeded(from: legacyURL, to: privateURL, fileManager: fileManager)
        }
    }

    private func migrateFileProtectionAcrossManagedDirectories() throws {
        for directory in ManagedDirectory.allCases {
            try ensureDirectoryExists(for: directory)
            try applyFileProtectionToDirectoryContents(for: directory)
        }
    }

    private func applyFileProtectionToDirectoryContents(for directory: ManagedDirectory) throws {
        let directoryURL = directoryURL(for: directory)
        for url in try contentsOfDirectory(at: directoryURL) {
            try applyFileProtection(to: url)
        }
    }

    private func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(Self.fileProtectionAttributes, ofItemAtPath: url.path)
    }
    #endif

    // MARK: - Private Helpers

    private nonisolated var applicationSupportDirectoryURL: URL {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationSupport")
        }
        return appSupportURL
    }

    private nonisolated func directoryURL(for directory: ManagedDirectory) -> URL {
        if directory.usesApplicationSupport {
            return applicationSupportDirectoryURL.appendingPathComponent(directory.folderName, isDirectory: true)
        }

        return documentsBackedDirectoryURL(named: directory.folderName)
    }

    private nonisolated func documentsBackedDirectoryURL(named folderName: String) -> URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(folderName)
        }
        return documentsURL.appendingPathComponent(folderName)
    }

    private func ensureDirectoryExists(for directory: ManagedDirectory) throws {
        if directory.usesApplicationSupport {
            try ensureApplicationSupportDirectoryExists()
        }

        let url = directoryURL(for: directory)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }

        try applyProtectionIfNeeded(to: url)
    }

    private func ensureApplicationSupportDirectoryExists() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: applicationSupportDirectoryURL.path) {
            try fileManager.createDirectory(at: applicationSupportDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        try applyProtectionIfNeeded(to: applicationSupportDirectoryURL)
    }

    private func ensureCoverArtDirectoryExists(for location: CoverArtLocation) throws {
        switch location {
        case .localLibrary:
            try setupCoverArtDirectory()
        case .remoteCache:
            try setupRemoteCoverArtDirectory()
        }
    }

    private func preparedLibraryDestinationURL(for name: String) throws -> URL {
        guard isSafeManagedFileName(name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try setupStoryCastLibraryDirectory()
        let uniqueName = uniqueFileName(for: name)
        return storyCastLibraryURL.appendingPathComponent(uniqueName)
    }

    private func normalizedCoverArtData(from data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else {
            return nil
        }

        let maxDimension = max(image.size.width * image.scale, image.size.height * image.scale)
        let cap: CGFloat = 600
        guard maxDimension > cap else {
            if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 { return data }
            return image.jpegData(compressionQuality: StorageDefaults.coverArtCompressionQuality)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(
            width: image.size.width * cap / maxDimension,
            height: image.size.height * cap / maxDimension
        ), format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderer.format.bounds.size))
        }
        return resized.jpegData(compressionQuality: StorageDefaults.coverArtCompressionQuality)
        #else
        return data
        #endif
    }

    private func writeData(_ data: Data, to destinationURL: URL) throws {
        try data.write(to: destinationURL, options: [.atomic])
        try applyProtectionIfNeeded(to: destinationURL)
    }

    private func moveOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            do {
                try fileManager.removeItem(at: sourceURL)
            } catch {
                AppLogger.storage.error("Failed to remove source file after copy: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }

    private func removeFiles(at fileURLs: [URL], errorMessage: String? = nil) {
        let fileManager = FileManager.default

        for fileURL in Set(fileURLs) {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    AppLogger.storage.warning("Skipped non-file storage cleanup target: \(fileURL.path)")
                    continue
                }
                try fileManager.removeItem(at: fileURL)
            } catch {
                let cocoaError = error as? CocoaError
                if cocoaError?.code == .fileNoSuchFile { continue }
                AppLogger.storage.error("Storage cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func isSafeManagedFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty &&
            fileName == (fileName as NSString).lastPathComponent &&
            fileName != "." &&
            fileName != ".." &&
            !fileName.contains("/") &&
            !fileName.unicodeScalars.contains("\u{0000}")
    }

    private func managedFileURL(in directoryURL: URL, named fileName: String) -> URL? {
        guard isSafeManagedFileName(fileName) else { return nil }
        let root = directoryURL.standardizedFileURL
        let fileURL = root.appendingPathComponent(fileName).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == root else { return nil }
        return fileURL
    }

    private func contentsOfDirectory(at directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    #if os(iOS)
    private func migrateFileIfNeeded(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
        let sourceExists = sourceAttributes != nil
        let destinationExists = destinationAttributes != nil

        guard sourceExists || destinationExists else { return }
        guard sourceAttributes?[.type] as? FileAttributeType == .typeRegular || !sourceExists else {
            AppLogger.storage.warning("Skipped non-file legacy remote asset: \(sourceURL.path)")
            return
        }
        guard destinationAttributes?[.type] as? FileAttributeType == .typeRegular || !destinationExists else {
            AppLogger.storage.warning("Skipped non-file remote cache destination: \(destinationURL.path)")
            return
        }

        if sourceExists && !destinationExists {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try applyProtectionIfNeeded(to: destinationURL)
            return
        }

        if sourceExists && destinationExists {
            try fileManager.removeItem(at: sourceURL)
        }
    }
    #endif

    private func uniqueFileName(for name: String) -> String {
        let fileManager = FileManager.default
        let destinationURL = storyCastLibraryURL.appendingPathComponent(name)

        if !fileManager.fileExists(atPath: destinationURL.path) {
            return name
        }

        let nameWithoutExtension = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        var candidateName = ""

        repeat {
            candidateName = "\(nameWithoutExtension) (\(counter))"
            if !ext.isEmpty {
                candidateName += ".\(ext)"
            }
            counter += 1
        } while fileManager.fileExists(atPath: storyCastLibraryURL.appendingPathComponent(candidateName).path)

        return candidateName
    }

    #if os(iOS)
    private func applyProtectionIfNeeded(to url: URL) throws {
        try applyFileProtection(to: url)
    }
    #else
    private func applyProtectionIfNeeded(to url: URL) throws {
    }
    #endif

    func resetAllData(container: ModelContainer? = nil) {
        let fileManager = FileManager.default
        var failedDeletions: [String] = []
        
        // Clear Keychain tokens before deleting the database
        if let container {
            let context = ModelContext(container)
            if let servers = try? context.fetch(FetchDescriptor<ABSServer>()) {
                for server in servers {
                    let key = server.normalizedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "StoryCast.AudiobookshelfToken",
                        kSecAttrAccount as String: key
                    ]
                    SecItemDelete(query as CFDictionary)
                }
            }
        }
        // Delete ABS device ID
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "StoryCast.ABSDeviceID",
            kSecAttrAccount as String: "deviceID"
        ] as CFDictionary)
        // Delete sync device identity
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "StoryCast.SyncDeviceIdentity",
            kSecAttrAccount as String: "current"
        ] as CFDictionary)
        
        for directory in ManagedDirectory.allCases {
            let url = directoryURL(for: directory)
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    AppLogger.storage.error("Failed to delete \(directory.folderName): \(error.localizedDescription, privacy: .private)")
                    failedDeletions.append(directory.folderName)
                }
            }
        }
        
        // Also delete SwiftData database files to prevent orphaned references
        if !StorageBackupManager.deleteDatabaseFiles() {
            failedDeletions.append("database")
        }
        
        if let bundleId = Bundle.main.bundleIdentifier {
            // This is a nuclear reset that removes ALL UserDefaults keys for this
            // app, including the iCloud sync opt-in toggle. On next launch, sync
            // will be off and the user must re-enable it in Settings.
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        
        if failedDeletions.isEmpty {
            AppLogger.app.info("All StoryCast data has been reset")
        } else {
            AppLogger.app.warning("Data reset completed but failed to delete: \(failedDeletions.joined(separator: ", "))")
        }
    }
}
