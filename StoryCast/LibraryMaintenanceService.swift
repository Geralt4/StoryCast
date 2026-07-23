import AVFoundation
import Foundation
import os
import SwiftData

enum LibraryMaintenanceService {
    struct RepairResult: Sendable { let staleRemovedCount: Int; let reassignedToUnfiledCount: Int; let createdUnfiledFolder: Bool }
    struct AdoptionResult: Sendable { let adoptedCount: Int }
    struct DeduplicationResult: Sendable { let removedCount: Int; let completed: Bool }

    static func ensureUnfiledFolderExists(container: ModelContainer) throws {
        let context = ModelContext(container)
        let resolution = try MaintenanceSupport.resolveUnfiledFolder(in: context)
        if resolution.created { try context.save() }
    }

    @discardableResult
    static func repairLibraryIntegrity(container: ModelContainer, libraryURL: URL = StorageManager.shared.storyCastLibraryURL) async -> RepairResult {
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()
        let result = await Task(priority: .utility) {
            IntegrityRepairPass.run(container: container, libraryURL: libraryURL, deviceID: deviceID)
        }.value
        switch result {
        case .failure(let error):
            AppLogger.app.error("Library integrity repair failed: \(error.localizedDescription)")
            return RepairResult(staleRemovedCount: 0, reassignedToUnfiledCount: 0, createdUnfiledFolder: false)
        case .success(let payload):
            if payload.result.staleRemovedCount > 0 || payload.result.reassignedToUnfiledCount > 0 {
                AppLogger.app.info("Library integrity repair completed: removed \(payload.result.staleRemovedCount) stale books, reassigned \(payload.result.reassignedToUnfiledCount) books to Unfiled")
            }
            return payload.result
        }
    }

    @discardableResult
    static func adoptManagedLibraryFiles(container: ModelContainer, libraryURL: URL = StorageManager.shared.storyCastLibraryURL) async -> AdoptionResult {
        let result = await Task(priority: .utility) { await ManagedLibraryAdoptionPass.run(container: container, libraryURL: libraryURL) }.value
        switch result {
        case .failure(let error):
            AppLogger.importService.error("Managed library adoption failed: \(error.localizedDescription)")
            return AdoptionResult(adoptedCount: 0)
        case .success(let adoptedCount):
            if adoptedCount > 0 { AppLogger.importService.info("Adopted \(adoptedCount) unmanaged library files in place") }
            return AdoptionResult(adoptedCount: adoptedCount)
        }
    }

    @discardableResult
    nonisolated static func deduplicateExistingBooks(container: ModelContainer, libraryURL: URL = StorageManager.shared.storyCastLibraryURL) async -> DeduplicationResult {
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()
        let result = await Task.detached(priority: .utility) { @MainActor in
            DeduplicationPass.run(container: container, libraryURL: libraryURL, deviceID: deviceID)
        }.value
        switch result {
        case .failure(let error):
            AppLogger.app.error("Library deduplication failed: \(error.localizedDescription)")
            return DeduplicationResult(removedCount: 0, completed: false)
        case .success(let payload):
            if payload.removedCount == 0 { AppLogger.app.info("Library deduplication completed: no duplicates found") }
            else { AppLogger.app.info("Library deduplication removed \(payload.removedCount) duplicate books") }
            return DeduplicationResult(removedCount: payload.removedCount, completed: true)
        }
    }

    @MainActor
    static func syncRemoteLibraries(container: ModelContainer) async {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.isActive })
        guard let servers = try? context.fetch(descriptor), !servers.isEmpty else {
            AppLogger.network.debug("No active Audiobookshelf servers to sync")
            return
        }
        let snapshots = servers.map { $0.snapshot() }
        AppLogger.network.info("Starting sync for \(snapshots.count) Audiobookshelf server(s)")
        for snapshot in snapshots {
            let result = await RemoteLibrarySyncEngine.syncPreferredLibrary(for: snapshot, container: container)
            switch result.outcome {
            case .synced(_, let libraryName): AppLogger.network.info("Synced library '\(libraryName)' from server '\(snapshot.name)'")
            case .skippedNoToken: AppLogger.network.warning("Token invalid for server \(snapshot.name)")
            case .skippedNoLibraries: AppLogger.network.info("No libraries available to sync for server '\(snapshot.name)'")
            case .failed(let message): AppLogger.network.error("Remote sync failed for server '\(snapshot.name)': \(message)")
            }
        }
    }
}

private enum IntegrityRepairPass {
    struct Payload { let result: LibraryMaintenanceService.RepairResult }

    @MainActor
    static func run(
        container: ModelContainer,
        libraryURL: URL,
        deviceID: String?
    ) -> Result<Payload, Error> {
        let context = ModelContext(container)
        do {
            let resolution = try MaintenanceSupport.resolveUnfiledFolder(in: context)
            let books = try context.fetch(FetchDescriptor<Book>())
            let syncedBookIDs = try MaintenanceSupport.syncedBookIDs(in: context)
            var booksToDelete: [Book] = []
            var reassignedToUnfiledCount = 0

            for book in books {
                if MaintenanceSupport.shouldValidateLocalLibraryFile(for: book) {
                    guard let localFileURL = MaintenanceSupport.managedLibraryFileURL(for: book.localFileName, libraryURL: libraryURL) else {
                        booksToDelete.append(book)
                        continue
                    }
                    switch MaintenanceSupport.fileStatus(at: localFileURL) {
                    case .regular:
                        break
                    case .missingOrInvalid:
                        if !syncedBookIDs.contains(book.id) {
                            booksToDelete.append(book)
                        }
                        continue
                    case .unavailable:
                        continue
                    }
                }
                if book.folder == nil { book.folder = resolution.folder; reassignedToUnfiledCount += 1 }
            }

            for book in booksToDelete {
                try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: deviceID, in: context)
            }
            if resolution.created || reassignedToUnfiledCount > 0 || !booksToDelete.isEmpty {
                try context.save()
            }

            StorageCleanupCoordinator.drainPendingCleanup(in: context)

            return .success(Payload(
                result: LibraryMaintenanceService.RepairResult(
                    staleRemovedCount: booksToDelete.count,
                    reassignedToUnfiledCount: reassignedToUnfiledCount,
                    createdUnfiledFolder: resolution.created
                )
            ))
        } catch {
            context.rollback()
            return .failure(error)
        }
    }
}

private enum ManagedLibraryAdoptionPass {
    @MainActor
    static func run(container: ModelContainer, libraryURL: URL) async -> Result<Int, Error> {
        let context = ModelContext(container)
        do {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .success(0) }

            let resolution = try MaintenanceSupport.resolveUnfiledFolder(in: context)
            let books = try context.fetch(FetchDescriptor<Book>())
            var trackedFileNames = Set(books.compactMap { MaintenanceSupport.trackedFileName(for: $0) })
            let syncedAudioFileNames = Set(
                try context.fetch(FetchDescriptor<SyncAsset>()).compactMap { asset -> String? in
                    guard asset.kindRaw == SyncAssetKind.audio.rawValue,
                          let relativePath = asset.localRelativePath,
                          StorageCleanupCoordinator.isSafeRelativePath(relativePath) else {
                        return nil
                    }
                    return relativePath
                }
            )
            let pendingCleanupFileNames = StorageCleanupCoordinator.pendingCleanupFileNames(
                for: .managedLibrary,
                in: context
            )
            let inboundAudioFileNames = try MaintenanceSupport.pendingInboundAudioFileNames(in: context)

            let fileURLs = try fileManager.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            var adoptedCount = 0

            for fileURL in fileURLs {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else { continue }
                let fileName = fileURL.lastPathComponent
                let isSupported = await MainActor.run { SupportedFormats.isSupported(fileURL) }
                guard !trackedFileNames.contains(fileName),
                      !syncedAudioFileNames.contains(fileName),
                      !pendingCleanupFileNames.contains(fileName),
                      !inboundAudioFileNames.contains(fileName),
                      isSupported else { continue }

                do {
                    let asset = AVURLAsset(url: fileURL)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0 else {
                        AppLogger.importService.warning("Skipping managed library adoption for \(fileName) because duration could not be determined")
                        continue
                    }

                    let metadata = try? await asset.load(.commonMetadata)
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
                    trackedFileNames.insert(fileName)
                    adoptedCount += 1
                } catch {
                    AppLogger.importService.warning("Skipping managed library adoption for \(fileName): \(error.localizedDescription)")
                }
            }

            if resolution.created || adoptedCount > 0 { try context.save() }
            return .success(adoptedCount)
        } catch {
            context.rollback()
            return .failure(error)
        }
    }
}

private enum DeduplicationPass {
    struct Payload { let removedCount: Int }

    @MainActor
    static func run(
        container: ModelContainer,
        libraryURL: URL,
        deviceID: String?
    ) -> Result<Payload, Error> {
        let context = ModelContext(container)
        do {
            let books = try context.fetch(FetchDescriptor<Book>())
            let syncedBookIDs = try MaintenanceSupport.syncedBookIDs(in: context)
            guard !books.isEmpty else { return .success(Payload(removedCount: 0)) }

            var booksToDelete: [Book] = []

            var staleBooks: [Book] = []
            for book in books {
                guard MaintenanceSupport.shouldValidateLocalLibraryFile(for: book) else { continue }
                guard let localFileURL = MaintenanceSupport.managedLibraryFileURL(for: book.localFileName, libraryURL: libraryURL) else {
                    staleBooks.append(book)
                    continue
                }
                if MaintenanceSupport.fileStatus(at: localFileURL) == .missingOrInvalid,
                   !syncedBookIDs.contains(book.id) {
                    staleBooks.append(book)
                }
            }

            var groupsByCanonicalPath: [String: [Book]] = [:]
            for book in books {
                guard MaintenanceSupport.shouldValidateLocalLibraryFile(for: book) else { continue }
                guard let canonicalPath = MaintenanceSupport.canonicalManagedPath(for: book.localFileName, libraryURL: libraryURL),
                      MaintenanceSupport.fileStatus(at: canonicalPath) == .regular else { continue }
                groupsByCanonicalPath[MaintenanceSupport.canonicalPathKey(for: canonicalPath), default: []].append(book)
            }

            for group in groupsByCanonicalPath.values where group.count > 1 {
                let keeper = group.max(by: { lhs, rhs in
                    let lhsDate = lhs.lastPlayedDate ?? .distantPast
                    let rhsDate = rhs.lastPlayedDate ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    if lhs.lastPlaybackPosition != rhs.lastPlaybackPosition {
                        return lhs.lastPlaybackPosition < rhs.lastPlaybackPosition
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                })
                guard let keeper else { continue }
                for book in group where book.id != keeper.id {
                    mergeMetadata(into: keeper, from: book)
                    booksToDelete.append(book)
                }
            }

            for book in staleBooks {
                booksToDelete.append(book)
            }

            for book in booksToDelete {
                try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: deviceID, in: context)
            }
            if !booksToDelete.isEmpty {
                try context.save()
                StorageCleanupCoordinator.drainPendingCleanup(in: context)
            }

            return .success(Payload(removedCount: booksToDelete.count))
        } catch {
            context.rollback()
            return .failure(error)
        }
    }

    private static func mergeMetadata(into keeper: Book, from loser: Book) {
        if (keeper.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let loserAuthor = loser.author,
           !loserAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keeper.author = loserAuthor
        }
        if keeper.duration <= 0, loser.duration > 0 {
            keeper.duration = loser.duration
        }
        if !keeper.isImported, loser.isImported {
            keeper.isImported = true
        }
        if keeper.folder == nil {
            keeper.folder = loser.folder
        }
        if keeper.coverArtFileName == nil,
           let loserCover = loser.coverArtFileName,
           StorageCleanupCoordinator.isSafeRelativePath(loserCover) {
            keeper.coverArtFileName = loserCover
        }
        var existingChapterKeys = Set(keeper.chapters.map(chapterKey))
        for chapter in Array(loser.chapters) {
            guard existingChapterKeys.insert(chapterKey(chapter)).inserted else { continue }
            chapter.book = keeper
        }
        keeper.updateSearchFields()
    }

    private static func chapterKey(_ chapter: Chapter) -> String {
        "\(chapter.startTime)|\(chapter.endTime)|\(chapter.source.rawValue)|\(chapter.title)"
    }
}

private enum MaintenanceSupport {
    nonisolated enum ManagedFileStatus: Equatable {
        case regular
        case missingOrInvalid
        case unavailable
    }

    @MainActor
    struct UnfiledResolution: Sendable { let folder: Folder; let created: Bool }

    nonisolated static func shouldValidateLocalLibraryFile(for book: Book) -> Bool { !book.isRemote }
    nonisolated static func trackedFileName(for book: Book) -> String? { shouldValidateLocalLibraryFile(for: book) ? validatedManagedFileName(book.localFileName) : nil }

    nonisolated static func validatedManagedFileName(_ fileName: String) -> String? {
        StorageCleanupCoordinator.isSafeRelativePath(fileName) ? fileName : nil
    }

    nonisolated static func managedLibraryFileURL(for fileName: String, libraryURL: URL) -> URL? {
        guard let validatedFileName = validatedManagedFileName(fileName) else { return nil }
        let fileURL = libraryURL.appendingPathComponent(validatedFileName).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == libraryURL.standardizedFileURL else { return nil }
        return fileURL
    }

    nonisolated static func canonicalManagedPath(for fileName: String, libraryURL: URL) -> URL? {
        managedLibraryFileURL(for: fileName, libraryURL: libraryURL)
    }

    nonisolated static func canonicalPathKey(for fileURL: URL) -> String {
        if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let identifier = resourceValues.fileResourceIdentifier {
            return "resource:\(String(describing: identifier))"
        }
        return "path:\(fileURL.standardizedFileURL.path)"
    }

    nonisolated static func fileStatus(at fileURL: URL) -> ManagedFileStatus {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attributes[.type] as? FileAttributeType == .typeRegular
                ? .regular
                : .missingOrInvalid
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .missingOrInvalid
        } catch {
            return .unavailable
        }
    }

    static func syncedBookIDs(in context: ModelContext) throws -> Set<UUID> {
        let assets = try context.fetch(FetchDescriptor<SyncAsset>())
        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        var bookIDs = Set(assets.map(\.bookID))
        for state in states where state.entityKindRaw == SyncEntityKind.book.rawValue {
            if let bookID = UUID(uuidString: state.localEntityID) {
                bookIDs.insert(bookID)
            }
        }
        return bookIDs
    }

    static func pendingInboundAudioFileNames(in context: ModelContext) throws -> Set<String> {
        let inboxes = try context.fetch(FetchDescriptor<SyncInboxRecord>())
        let retries = try context.fetch(FetchDescriptor<SyncInboxRetryState>())
        let retriesByRecordName = Dictionary(uniqueKeysWithValues: retries.map { ($0.recordName, $0) })
        var names: Set<String> = []
        for inbox in inboxes {
            guard inbox.recordType == CloudSyncRecordType.asset.rawValue,
                  inbox.stateRaw != "applied",
                  let payload = try? CloudSyncRecordCodec.decodePayload(
                      CloudSyncAssetPayload.self,
                      from: inbox.payloadData
                  ),
                  payload.kind == .audio else {
                continue
            }
            let extensionValue = payload.pathExtension.lowercased()
            guard extensionValue.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-")).contains($0)
            }) else {
                continue
            }
            let suffix = extensionValue.isEmpty ? "" : ".\(extensionValue)"
            let defaultName = "icloud-\(payload.assetID.uuidString.lowercased())\(suffix)"
            if StorageCleanupCoordinator.isSafeRelativePath(defaultName) {
                names.insert(defaultName)
            }
            let fallbackName = "icloud-sync-\(payload.assetID.uuidString.lowercased())\(suffix)"
            if StorageCleanupCoordinator.isSafeRelativePath(fallbackName) {
                names.insert(fallbackName)
            }
            if let claimID = retriesByRecordName[inbox.id]?.claimID {
                let claimedName = "icloud-sync-\(payload.assetID.uuidString.lowercased())-\(claimID.uuidString.prefix(8).lowercased())\(suffix)"
                if StorageCleanupCoordinator.isSafeRelativePath(claimedName) {
                    names.insert(claimedName)
                }
            }
        }
        return names
    }

    static func resolveUnfiledFolder(in context: ModelContext) throws -> UnfiledResolution {
        var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        unfiledFetch.fetchLimit = 1
        if let existing = try context.fetch(unfiledFetch).first { return UnfiledResolution(folder: existing, created: false) }
        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(folder)
        return UnfiledResolution(folder: folder, created: true)
    }

    nonisolated static func authorFromMetadata(_ metadata: [AVMetadataItem]) async -> String? {
        let candidateKeys = Set(["author", "artist", "albumartist", "creator"])
        for item in metadata {
            guard let key = item.commonKey?.rawValue.lowercased(), candidateKeys.contains(key) else { continue }
            if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = try? await item.load(.value) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }
}
