import Foundation
import os
#if os(iOS)
import UIKit
#endif

actor StorageManager {

    static let shared = StorageManager()
    #if os(iOS)
    private static let fileProtectionAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    #endif
    
    nonisolated var voiceBoxLibraryURL: URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBoxLibrary")
        }
        return documentsURL.appendingPathComponent("VoiceBoxLibrary")
    }

    nonisolated var coverArtDirectoryURL: URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("CoverArt")
        }
        return documentsURL.appendingPathComponent("CoverArt")
    }

    func setupVoiceBoxLibraryDirectory() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: voiceBoxLibraryURL.path) {
            try fileManager.createDirectory(at: voiceBoxLibraryURL, withIntermediateDirectories: true, attributes: nil)
        }
        #if os(iOS)
        try applyFileProtection(to: voiceBoxLibraryURL)
        #endif
    }

    func setupCoverArtDirectory() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: coverArtDirectoryURL.path) {
            try fileManager.createDirectory(at: coverArtDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        #if os(iOS)
        try applyFileProtection(to: coverArtDirectoryURL)
        #endif
    }

    nonisolated func coverArtURL(for fileName: String) -> URL {
        coverArtDirectoryURL.appendingPathComponent(fileName)
    }

    func saveCoverArt(_ data: Data, for bookId: UUID) throws -> String? {
        guard UIImage(data: data) != nil else {
            return nil
        }

        let fileName = "\(bookId.uuidString).jpg"
        let destinationURL = coverArtURL(for: fileName)

        try setupCoverArtDirectory()

        // If the input is already JPEG, write it directly to avoid lossy re-encoding
        let dataToWrite: Data
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            dataToWrite = data
        } else {
            guard let image = UIImage(data: data),
                  let jpegData = image.jpegData(compressionQuality: StorageDefaults.coverArtCompressionQuality) else {
                return nil
            }
            dataToWrite = jpegData
        }

        try dataToWrite.write(to: destinationURL, options: [.atomic])
        #if os(iOS)
        try applyFileProtection(to: destinationURL)
        #endif
        return fileName
    }

    func deleteCoverArt(fileName: String) {
        let fileManager = FileManager.default
        let fileURL = coverArtURL(for: fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            AppLogger.storage.error("Error deleting cover art: \(error.localizedDescription, privacy: .private)")
        }
    }

    func copyFileToVoiceBoxLibraryDirectory(from sourceURL: URL, withName name: String) throws -> URL {
        try setupVoiceBoxLibraryDirectory()
        let uniqueName = uniqueFileName(for: name)
        let destinationURL = voiceBoxLibraryURL.appendingPathComponent(uniqueName)
        // Use FileManager copyItem which is synchronous but we're calling it in Task.detached
        let fileManager = FileManager.default
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        #if os(iOS)
        try applyFileProtection(to: destinationURL)
        #endif
        return destinationURL
    }

    #if os(iOS)
    func migrateFileProtectionIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: StorageDefaults.fileProtectionMigrationKey) else {
            return
        }
        try setupVoiceBoxLibraryDirectory()
        try setupCoverArtDirectory()
        let fileManager = FileManager.default
        let voiceBoxLibraryURLs = try fileManager.contentsOfDirectory(
            at: voiceBoxLibraryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in voiceBoxLibraryURLs {
            try applyFileProtection(to: url)
        }
        let coverArtURLs = try fileManager.contentsOfDirectory(
            at: coverArtDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in coverArtURLs {
            try applyFileProtection(to: url)
        }
        UserDefaults.standard.set(true, forKey: StorageDefaults.fileProtectionMigrationKey)
    }

    private func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(Self.fileProtectionAttributes, ofItemAtPath: url.path)
    }
    #endif

    private func uniqueFileName(for name: String) -> String {
        let fileManager = FileManager.default
        let destinationURL = voiceBoxLibraryURL.appendingPathComponent(name)
        
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
        } while fileManager.fileExists(atPath: voiceBoxLibraryURL.appendingPathComponent(candidateName).path)
        
        return candidateName
    }
}
