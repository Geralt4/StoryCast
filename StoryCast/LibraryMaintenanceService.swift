import AVFoundation
import Foundation
import os
import SwiftData

enum LibraryMaintenanceService {
    struct RepairResult: Sendable {
        let staleRemovedCount: Int
        let reassignedToUnfiledCount: Int
        let createdUnfiledFolder: Bool
    }

    struct AdoptionResult: Sendable {
        let adoptedCount: Int
    }

    struct DeduplicationResult: Sendable {
        let removedCount: Int
        let completed: Bool
    }

    static func ensureUnfiledFolderExists(container: ModelContainer) throws {
        let context = ModelContext(container)
        _ = try MaintenanceSupport.resolveUnfiledFolder(in: context)
    }

    @discardableResult
    static func repairLibraryIntegrity(
        container: ModelContainer,
        libraryURL: URL = StorageManager.shared.storyCastLibraryURL
    ) async -> RepairResult {
        let result = await Task(priority: .utility) {
            IntegrityRepairPass.run(container: container, libraryURL: libraryURL)
        }.value

        switch result {
        case .failure(let error):
            AppLogger.app.error("Library integrity repair failed: \(error.localizedDescription)")
            return RepairResult(staleRemovedCount: 0, reassignedToUnfiledCount: 0, createdUnfiledFolder: false)
        case .success(let payload):
            for coverArtFileName in payload.coverArtFileNames {
                await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName)
            }

            if payload.result.staleRemovedCount > 0 || payload.result.reassignedToUnfiledCount > 0 {
                AppLogger.app.info(
                    "Library integrity repair completed: removed \(payload.result.staleRemovedCount) stale books, reassigned \(payload.result.reassignedToUnfiledCount) books to Unfiled"
                )
            }

            return payload.result
        }
    }

    @discardableResult
    static func adoptManagedLibraryFiles(
        container: ModelContainer,
        libraryURL: URL = StorageManager.shared.storyCastLibraryURL
    ) async -> AdoptionResult {
        let result = await Task(priority: .utility) {
            await ManagedLibraryAdoptionPass.run(container: container, libraryURL: libraryURL)
        }.value

        switch result {
        case .failure(let error):
            AppLogger.importService.error("Managed library adoption failed: \(error.localizedDescription)")
            return AdoptionResult(adoptedCount: 0)
        case .success(let adoptedCount):
            if adoptedCount > 0 {
                AppLogger.importService.info("Adopted \(adoptedCount) unmanaged library files in place")
            }
            return AdoptionResult(adoptedCount: adoptedCount)
        }
    }

    @discardableResult
    nonisolated static func deduplicateExistingBooks(
        container: ModelContainer,
        libraryURL: URL = StorageManager.shared.storyCastLibraryURL
    ) async -> DeduplicationResult {
        let result = await Task.detached(priority: .utility) {
            DeduplicationPass.run(container: container, libraryURL: libraryURL)
        }.value

        switch result {
        case .failure(let error):
            AppLogger.app.error("Library deduplication failed: \(error.localizedDescription)")
            return DeduplicationResult(removedCount: 0, completed: false)
        case .success(let payload):
            for fileName in payload.localFileNames {
                MaintenanceSupport.removeManagedLibraryFile(named: fileName, libraryURL: libraryURL)
            }

            for fileName in payload.coverArtFileNames {
                await StorageManager.shared.deleteCoverArt(fileName: fileName)
            }

            if payload.removedCount == 0 {
                AppLogger.app.info("Library deduplication completed: no duplicates found")
            } else {
                AppLogger.app.info("Library deduplication removed \(payload.removedCount) duplicate books")
            }

            return DeduplicationResult(removedCount: payload.removedCount, completed: true)
        }
    }

    nonisolated static func syncRemoteLibraries(container: ModelContainer) async {
        await RemoteSyncPass.run(container: container)
    }
}

private enum IntegrityRepairPass {
    struct Payload {
        let result: LibraryMaintenanceService.RepairResult
        let coverArtFileNames: [String]
    }

static func run(container: ModelContainer, libraryURL: URL) -> Result<Payload, Error> {
        do {
            let context = ModelContext(container)
            let resolution = try MaintenanceSupport.resolveUnfiledFolder(in: context)
            let books = try context.fetch(FetchDescriptor<Book>())

            var coverArtFileNamesToDelete = Set<String>()
            var booksToDelete: [Book] = []
            var reassignedToUnfiledCount = 0

            for book in books {
                if MaintenanceSupport.shouldValidateLocalLibraryFile(for: book) {
                    guard let localFileURL = MaintenanceSupport.managedLibraryFileURL(for: book.localFileName, libraryURL: libraryURL),
                          FileManager.default.fileExists(atPath: localFileURL.path) else {
                        booksToDelete.append(book)
                        if let coverArtFileName = book.coverArtFileName {
                            coverArtFileNamesToDelete.insert(coverArtFileName)
                        }
                        continue
                    }
                }

                if book.folder == nil {
                    book.folder = resolution.folder
                    reassignedToUnfiledCount += 1
                }
            }

            for book in booksToDelete {
                context.delete(book)
            }

            if reassignedToUnfiledCount > 0 || !booksToDelete.isEmpty {
                try context.save()
            }

            return .success(
                Payload(
                    result: LibraryMaintenanceService.RepairResult(
                        staleRemovedCount: booksToDelete.count,
                        reassignedToUnfiledCount: reassignedToUnfiledCount,
                        createdUnfiledFolder: resolution.created
                    ),
                    coverArtFileNames: Array(coverArtFileNamesToDelete)
                )
            )
        } catch {
            return .failure(error)
        }
    }
}

private enum ManagedLibraryAdoptionPass {
    static func run(container: ModelContainer, libraryURL: URL) async -> Result<Int, Error> {
        do {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .success(0)
            }

            let context = ModelContext(container)
            let resolution = try MaintenanceSupport.resolveUnfiledFolder(in: context)
            let books = try context.fetch(FetchDescriptor<Book>())
            let trackedFileNames = Set(books.compactMap { MaintenanceSupport.trackedFileName(for: $0) })

            guard let enumerator = fileManager.enumerator(
                at: libraryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return .success(0)
            }

            var adoptedCount = 0

            while let fileURL = enumerator.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else { continue }

                let fileName = fileURL.lastPathComponent
                let isSupported = await MainActor.run {
                    SupportedFormats.isSupported(fileURL)
                }

                guard !trackedFileNames.contains(fileName), isSupported else {
                    continue
                }

                let asset = AVURLAsset(url: fileURL)
                let assetDuration = try await asset.load(.duration)
                let duration = assetDuration.seconds
                guard duration.isFinite, duration > 0 else {
                    AppLogger.importService.warning(
                        "Skipping managed library adoption for \(fileName) because duration could not be determined"
                    )
                    continue
                }

                let metadata: [AVMetadataItem]?
                do {
                    metadata = try await asset.load(.commonMetadata)
                } catch {
                    AppLogger.importService.debug("Could not load common metadata for \(fileName): \(error.localizedDescription, privacy: .private)")
                    metadata = nil
                }
                let author = await MaintenanceSupport.authorFromMetadata(metadata ?? [])

                let book = Book(
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    author: author,
                    localFileName: fileName,
                    duration: duration,
                    isImported: true,
                    folder: resolution.folder
                )
                context.insert(book)
                adoptedCount += 1
            }

            if adoptedCount > 0 {
                try context.save()
            }

            return .success(adoptedCount)
        } catch {
            return .failure(error)
        }
    }
}

private enum DeduplicationPass {
    struct Payload {
        let removedCount: Int
        let localFileNames: [String]
        let coverArtFileNames: [String]
    }

    nonisolated static func run(container: ModelContainer, libraryURL: URL) -> Result<Payload, Error> {
        do {
            let context = ModelContext(container)
            let books = try context.fetch(FetchDescriptor<Book>())
            guard !books.isEmpty else {
                return .success(Payload(removedCount: 0, localFileNames: [], coverArtFileNames: []))
            }

            var localFileNamesToDelete = Set<String>()
            var coverArtFileNamesToDelete = Set<String>()
            var booksToDelete: [Book] = []
            var activeBooks: [Book] = []
            activeBooks.reserveCapacity(books.count)

            for book in books {
                guard MaintenanceSupport.shouldValidateLocalLibraryFile(for: book) else { continue }

                guard let localFileURL = MaintenanceSupport.managedLibraryFileURL(for: book.localFileName, libraryURL: libraryURL),
                      FileManager.default.fileExists(atPath: localFileURL.path) else {
                    booksToDelete.append(book)
                    if let coverArtFileName = book.coverArtFileName {
                        coverArtFileNamesToDelete.insert(coverArtFileName)
                    }
                    continue
                }

                activeBooks.append(book)
            }

            let groupedBooks = Dictionary(grouping: activeBooks, by: MaintenanceSupport.deduplicationKey)

            for group in groupedBooks.values where group.count > 1 {
                processGroup(
                    group,
                    booksToDelete: &booksToDelete,
                    localFileNamesToDelete: &localFileNamesToDelete,
                    coverArtFileNamesToDelete: &coverArtFileNamesToDelete
                )
            }

            for book in booksToDelete {
                context.delete(book)
            }

            if !booksToDelete.isEmpty {
                try context.save()
            }

            return .success(
                Payload(
                    removedCount: booksToDelete.count,
                    localFileNames: Array(localFileNamesToDelete),
                    coverArtFileNames: Array(coverArtFileNamesToDelete)
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func processGroup(
        _ group: [Book],
        booksToDelete: inout [Book],
        localFileNamesToDelete: inout Set<String>,
        coverArtFileNamesToDelete: inout Set<String>
    ) {
        let sortedByDuration = group.sorted { $0.duration < $1.duration }
        var cluster: [Book] = []
        var clusterAnchorDuration: Double = 0

        func processCluster(_ booksInCluster: [Book]) {
            guard booksInCluster.count > 1 else { return }
            var keeper = booksInCluster[0]

            for candidate in booksInCluster.dropFirst() where MaintenanceSupport.shouldPrefer(candidate, over: keeper) {
                keeper = candidate
            }

            for book in booksInCluster where book.id != keeper.id {
                booksToDelete.append(book)
                if let localFileName = MaintenanceSupport.trackedFileName(for: book) {
                    localFileNamesToDelete.insert(localFileName)
                }
                if let coverArtFileName = book.coverArtFileName {
                    coverArtFileNamesToDelete.insert(coverArtFileName)
                }
            }
        }

        for book in sortedByDuration {
            if cluster.isEmpty {
                cluster = [book]
                clusterAnchorDuration = book.duration
                continue
            }

            if abs(book.duration - clusterAnchorDuration) <= 1.0 {
                cluster.append(book)
            } else {
                processCluster(cluster)
                cluster = [book]
                clusterAnchorDuration = book.duration
            }
        }

        processCluster(cluster)
    }
}

private enum RemoteSyncPass {
    nonisolated static func run(container: ModelContainer) async {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.isActive })

        let servers: [ABSServer]
        do {
            servers = try context.fetch(descriptor)
        } catch {
            AppLogger.network.error("Failed to fetch active servers for sync: \(error.localizedDescription, privacy: .private)")
            return
        }

        guard !servers.isEmpty else {
            AppLogger.network.debug("No active Audiobookshelf servers to sync")
            return
        }

        let snapshots = servers.map { $0.snapshot() }
        AppLogger.network.info("Starting sync for \(snapshots.count) Audiobookshelf server(s)")

        for snapshot in snapshots {
            let result = await RemoteLibrarySyncEngine.syncPreferredLibrary(for: snapshot, container: container)
            switch result.outcome {
            case .synced(_, let libraryName):
                AppLogger.network.info("Synced library '\(libraryName)' from server '\(snapshot.name)'")
            case .skippedNoToken:
                AppLogger.network.warning("Token invalid for server \(snapshot.name)")
            case .skippedNoLibraries:
                AppLogger.network.info("No libraries available to sync for server '\(snapshot.name)'")
            case .failed(let message):
                AppLogger.network.error("Remote sync failed for server '\(snapshot.name)': \(message)")
            }
        }
    }
}

private enum MaintenanceSupport {
    @MainActor
    struct UnfiledResolution: Sendable {
        let folder: Folder
        let created: Bool
    }

    nonisolated static func deduplicationKey(for book: Book) -> String {
        let normalizedTitle = normalized(book.title)
        let normalizedAuthor = normalized(book.author ?? "")
        return "\(normalizedTitle)|\(normalizedAuthor)"
    }

    nonisolated static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated static func shouldPrefer(_ lhs: Book, over rhs: Book) -> Bool {
        let lhsDate = lhs.lastPlayedDate ?? .distantPast
        let rhsDate = rhs.lastPlayedDate ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        if lhs.lastPlaybackPosition != rhs.lastPlaybackPosition {
            return lhs.lastPlaybackPosition > rhs.lastPlaybackPosition
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    nonisolated static func shouldValidateLocalLibraryFile(for book: Book) -> Bool {
        !book.isRemote
    }

    nonisolated static func trackedFileName(for book: Book) -> String? {
        guard shouldValidateLocalLibraryFile(for: book) else { return nil }
        return validatedManagedFileName(book.localFileName)
    }

    nonisolated static func validatedManagedFileName(_ fileName: String) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              trimmed != ".",
              trimmed != ".." else {
            return nil
        }
        return trimmed
    }

    nonisolated static func managedLibraryFileURL(for fileName: String, libraryURL: URL) -> URL? {
        guard let validatedFileName = validatedManagedFileName(fileName) else { return nil }
        let fileURL = libraryURL.appendingPathComponent(validatedFileName).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == libraryURL.standardizedFileURL else {
            return nil
        }
        return fileURL
    }

    nonisolated static func removeManagedLibraryFile(named fileName: String, libraryURL: URL) {
        guard let fileURL = managedLibraryFileURL(for: fileName, libraryURL: libraryURL) else {
            AppLogger.storage.warning("Skipped unsafe library file deletion for \(fileName)")
            return
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            AppLogger.storage.error("Failed to delete library file: \(error.localizedDescription)")
        }
    }

    static func resolveUnfiledFolder(in context: ModelContext) throws -> UnfiledResolution {
        var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        unfiledFetch.fetchLimit = 1

        if let existing = try context.fetch(unfiledFetch).first {
            return UnfiledResolution(folder: existing, created: false)
        }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(folder)
        try context.save()
        return UnfiledResolution(folder: folder, created: true)
    }

    nonisolated static func authorFromMetadata(_ metadata: [AVMetadataItem]) async -> String? {
        let candidateKeys = Set(["author", "artist", "albumartist", "creator"])
        for item in metadata {
            guard let key = item.commonKey?.rawValue.lowercased(), candidateKeys.contains(key) else { continue }
            do {
                if let value = try await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            } catch {
                AppLogger.importService.debug("Could not load stringValue for metadata key \(key): \(error.localizedDescription, privacy: .private)")
            }
            do {
                if let value = try await item.load(.value), let stringValue = value as? String {
                    let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            } catch {
                AppLogger.importService.debug("Could not load raw value for metadata key \(key): \(error.localizedDescription, privacy: .private)")
            }
        }
        return nil
    }
}
