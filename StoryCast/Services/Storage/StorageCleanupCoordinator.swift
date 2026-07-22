import Foundation
import SwiftData
import os

enum CleanupLocation: String, Codable, Sendable, Hashable {
    case managedLibrary
    case coverArt
    case remoteAudioCache
    case remoteCoverArt
    case syncInboxStaging
}

@MainActor
enum StorageCleanupCoordinator {

    /// Managed filenames are opaque identifiers. Do not trim or normalize them:
    /// a filename containing leading or trailing whitespace is distinct on disk.
    nonisolated static func isSafeRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              relativePath == (relativePath as NSString).lastPathComponent,
              relativePath != ".", relativePath != "..",
              !relativePath.contains("/"),
              !relativePath.unicodeScalars.contains("\u{0000}") else {
            return false
        }
        // Normalize to NFKC and re-validate. This blocks Unicode normalization
        // tricks like full-width dots (U+FF0E) that decode to "." / ".."
        // after filesystem or URL-component normalization, which could
        // otherwise slip past the literal "." / ".." check above.
        let normalized = relativePath.precomposedStringWithCompatibilityMapping
        guard normalized == relativePath else {
            return false
        }
        return true
    }

    /// Stages a file deletion in the same transaction as the model mutation that
    /// made the file eligible for cleanup. Existing identical intents are reused.
    @discardableResult
    static func stage(
        location: CleanupLocation,
        relativePath: String,
        in context: ModelContext
    ) throws -> Bool {
        guard isSafeRelativePath(relativePath) else {
            AppLogger.storage.warning("Skipped staging unsafe cleanup path: \(relativePath)")
            return false
        }

        let entries = try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>())
        guard !entries.contains(where: {
            $0.locationRaw == location.rawValue && $0.relativePath == relativePath
        }) else {
            return false
        }

        context.insert(StorageCleanupJournalEntry(
            locationRaw: location.rawValue,
            relativePath: relativePath
        ))
        return true
    }

    @discardableResult
    static func drainPendingCleanup(
        in context: ModelContext,
        removing removeFileAtURL: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Int {
        let entries: [StorageCleanupJournalEntry]
        let books: [Book]
        let assets: [SyncAsset]
        let retryStates: [SyncInboxRetryState]
        do {
            entries = try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>())
            books = try context.fetch(FetchDescriptor<Book>())
            assets = try context.fetch(FetchDescriptor<SyncAsset>())
            retryStates = try context.fetch(FetchDescriptor<SyncInboxRetryState>())
        } catch {
            AppLogger.storage.error("Failed to fetch cleanup journal: \(error.localizedDescription)")
            return 0
        }

        let activeStagingPaths = Set(retryStates.compactMap { $0.stagedAssetRelativePath })

        var removedCount = 0
        var didMutate = false
        for entry in entries {
            switch removeFile(for: entry, books: books, assets: assets, activeStagingPaths: activeStagingPaths, removing: removeFileAtURL) {
            case .removed:
                context.delete(entry)
                removedCount += 1
                didMutate = true
            case .stillReferenced:
                // Keep the intent: when the final reference disappears, the same
                // journal entry becomes eligible without a second write.
                break
            case .retry(let message):
                entry.attemptCount += 1
                entry.lastErrorMessage = message
                didMutate = true
            case .discard(let message):
                AppLogger.storage.warning("Discarded unsafe cleanup entry for \(entry.relativePath): \(message)")
                context.delete(entry)
                didMutate = true
            }
        }

        do {
            if didMutate { try context.save() }
        } catch {
            AppLogger.storage.error("Failed to save cleanup journal drain: \(error.localizedDescription)")
        }

        return removedCount
    }

    static func pendingCleanupFileNames(
        for location: CleanupLocation,
        in context: ModelContext
    ) -> Set<String> {
        let entries: [StorageCleanupJournalEntry]
        do {
            entries = try context.fetch(FetchDescriptor<StorageCleanupJournalEntry>())
        } catch {
            return []
        }
        return Set(entries.compactMap { $0.locationRaw == location.rawValue ? $0.relativePath : nil })
    }

    private enum RemovalResult {
        case removed
        case stillReferenced
        case retry(String)
        case discard(String)
    }

    private static func removeFile(
        for entry: StorageCleanupJournalEntry,
        books: [Book],
        assets: [SyncAsset],
        activeStagingPaths: Set<String>,
        removing removeFileAtURL: (URL) throws -> Void
    ) -> RemovalResult {
        guard let location = CleanupLocation(rawValue: entry.locationRaw) else {
            return .discard("unknown cleanup location \(entry.locationRaw)")
        }

        if location == .syncInboxStaging, activeStagingPaths.contains(entry.relativePath) {
            return .stillReferenced
        }

        guard isSafeRelativePath(entry.relativePath),
              let fileURL = managedFileURL(location: location, relativePath: entry.relativePath) else {
            return .discard("path is not a direct managed file")
        }

        guard !isReferenced(
            location: location,
            relativePath: entry.relativePath,
            targetURL: fileURL,
            books: books,
            assets: assets
        ) else {
            return .stillReferenced
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .discard("target is not a regular file")
            }
            try removeFileAtURL(fileURL)
            return .removed
        } catch {
            let cocoaError = error as? CocoaError
            if cocoaError?.code == .fileNoSuchFile {
                return .removed
            }
            AppLogger.storage.error("Cleanup failed for \(entry.relativePath): \(error.localizedDescription)")
            return .retry(error.localizedDescription)
        }
    }

    private static func isReferenced(
        location: CleanupLocation,
        relativePath: String,
        targetURL: URL,
        books: [Book],
        assets: [SyncAsset]
    ) -> Bool {
        let referencedPaths: [String]
        switch location {
        case .managedLibrary:
            referencedPaths = books.compactMap { book in
                guard !book.isRemote else { return nil }
                return book.localFileName
            } + assets.compactMap { asset in
                guard asset.kindRaw == SyncAssetKind.audio.rawValue else { return nil }
                return asset.localRelativePath
            }
        case .coverArt:
            referencedPaths = books.compactMap { book in
                guard !book.isRemote else { return nil }
                return book.coverArtFileName
            } + assets.compactMap { asset in
                guard asset.kindRaw == SyncAssetKind.coverArt.rawValue else { return nil }
                return asset.localRelativePath
            }
        case .remoteAudioCache:
            referencedPaths = books.compactMap { $0.isRemote ? $0.localCachePath : nil }
        case .remoteCoverArt:
            referencedPaths = books.compactMap { $0.isRemote ? $0.coverArtFileName : nil }
        case .syncInboxStaging:
            referencedPaths = []
        }

        return referencedPaths.contains { candidatePath in
            guard candidatePath != relativePath else { return true }
            return sameManagedFile(
                location: location,
                targetURL: targetURL,
                candidatePath: candidatePath
            )
        }
    }

    private static func sameManagedFile(
        location: CleanupLocation,
        targetURL: URL,
        candidatePath: String
    ) -> Bool {
        guard let candidateURL = managedFileURL(location: location, relativePath: candidatePath),
              let targetIdentifier = fileResourceIdentifier(for: targetURL),
              let candidateIdentifier = fileResourceIdentifier(for: candidateURL) else {
            return false
        }
        return targetIdentifier == candidateIdentifier
    }

    private static func fileResourceIdentifier(for fileURL: URL) -> String? {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = resourceValues.fileResourceIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }

    private static var syncInboxStagingDirectoryURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupportURL.appendingPathComponent("StoryCast/SyncInboxAssets", isDirectory: true)
    }

    private static func managedFileURL(
        location: CleanupLocation,
        relativePath: String
    ) -> URL? {
        let directoryURL: URL
        switch location {
        case .managedLibrary:
            directoryURL = StorageManager.shared.storyCastLibraryURL
        case .coverArt:
            directoryURL = StorageManager.shared.coverArtDirectoryURL
        case .remoteAudioCache:
            directoryURL = StorageManager.shared.remoteAudioCacheDirectoryURL
        case .remoteCoverArt:
            directoryURL = StorageManager.shared.remoteCoverArtDirectoryURL
        case .syncInboxStaging:
            directoryURL = syncInboxStagingDirectoryURL
        }

        let root = directoryURL.standardizedFileURL
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == root else { return nil }
        return fileURL
    }
}
