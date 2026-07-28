import CloudKit
import CryptoKit
import Foundation
import SwiftData

enum SyncInboxError: LocalizedError {
    case missingAsset(recordName: String)
    case invalidAsset(recordName: String)
    case generationMismatch(local: String, remote: String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return "The iCloud asset for \(name) is unavailable."
        case .invalidAsset(let name):
            return "The downloaded iCloud asset for \(name) failed verification."
        case .generationMismatch:
            return "This device is linked to a different StoryCast iCloud library."
        }
    }
}

/// Stages CloudKit records before applying them to the local-only SwiftData
/// store. Records may arrive out of order; the drain pass applies only records
/// whose folders, books, and verified assets are already present.
@MainActor
enum SyncInboxApplier {
    static func stage(
        record: CKRecord,
        container: ModelContainer,
        drainAfterStaging: Bool = true
    ) async throws {
        guard let type = CloudSyncRecordType(rawValue: record.recordType) else {
            throw CloudSyncRecordCodecError.unsupportedRecordType(record.recordType)
        }

        let context = ModelContext(container)
        try SyncRecordSystemFieldsStore.persist(record: record, kind: entityKind(for: type), in: context)
        let payloadData = try CloudSyncRecordCodec.payloadData(from: record)
        let inbox = upsertInbox(
            id: record.recordID.recordName,
            recordType: record.recordType,
            payloadData: payloadData,
            in: context
        )
        if type == .asset {
            let payload = try CloudSyncRecordCodec.decode(
                CloudSyncAssetPayload.self,
                from: record,
                expectedType: .asset
            )
            if isTombstoned(kind: .book, entityID: payload.bookID.uuidString, in: context) {
                inbox.stateRaw = "applied"
                try stageStaleRetryCleanup(for: inbox.id, in: context)
            } else if !shouldInstallAsset(payload, in: context) {
                inbox.stateRaw = "applied"
                try stageStaleRetryCleanup(for: inbox.id, in: context)
            } else {
                let sourceURL = CloudSyncRecordCodec.assetFileURL(from: record)
                let stagedURL: URL
                if let sourceURL {
                    do {
                        stagedURL = try await stageIncomingAsset(sourceURL, for: payload)
                    } catch {
                        try recordRetry(for: inbox, error: error, in: context)
                        try context.save()
                        throw error
                    }
                    let retry = try retryState(for: inbox, in: context)
                    if let oldStagedPath = retry.stagedAssetRelativePath,
                       oldStagedPath != stagedURL.lastPathComponent {
                        _ = try StorageCleanupCoordinator.stage(
                            location: .syncInboxStaging,
                            relativePath: oldStagedPath,
                            in: context
                        )
                    }
                    retry.stagedAssetRelativePath = stagedURL.lastPathComponent
                    retry.claimID = retry.claimID ?? UUID()
                    retry.nextRetryAt = nil
                    retry.lastErrorMessage = nil
                    retry.updatedAt = Date()
                    try context.save()
                } else if let retry = try existingRetryState(for: inbox.id, in: context),
                          let stagedPath = retry.stagedAssetRelativePath,
                          let existingURL = stagedAssetURL(for: stagedPath),
                          FileManager.default.fileExists(atPath: existingURL.path) {
                    stagedURL = existingURL
                } else {
                    try recordRetry(for: inbox, error: SyncInboxError.missingAsset(recordName: record.recordID.recordName), in: context)
                    try context.save()
                    throw SyncInboxError.missingAsset(recordName: record.recordID.recordName)
                }
                do {
                    let claimID = try existingRetryState(for: inbox.id, in: context)?.claimID
                    let installed = try await installAsset(payload: payload, temporaryURL: stagedURL, claimID: claimID, in: context)
                    upsertAsset(payload: payload, localFileName: installed.lastPathComponent, in: context)
                    updateBookAssetReferences(payload: payload, localFileName: installed.lastPathComponent, in: context)
                    inbox.stateRaw = "applied"
                    if let retry = try existingRetryState(for: inbox.id, in: context) {
                        if let stagedPath = retry.stagedAssetRelativePath {
                            _ = try StorageCleanupCoordinator.stage(
                                location: .syncInboxStaging,
                                relativePath: stagedPath,
                                in: context
                            )
                        }
                        context.delete(retry)
                    }
                    try context.save()
                    StorageCleanupCoordinator.drainPendingCleanup(in: context)
                } catch {
                    try recordRetry(for: inbox, error: error, in: context)
                    try context.save()
                    throw error
                }
            }
        } else {
            try clearRetryState(for: inbox.id, in: context)
        }

        try context.save()
        if drainAfterStaging {
            try await drain(container: container)
        }
    }

    static func drain(container: ModelContainer) async throws {
        let context = ModelContext(container)
        var madeProgress = true

        while madeProgress {
            madeProgress = false
            let retryStates = try context.fetch(FetchDescriptor<SyncInboxRetryState>())
            let retriesByRecordName = Dictionary(uniqueKeysWithValues: retryStates.map { ($0.recordName, $0) })
            let now = Date()
            let pending = try context.fetch(FetchDescriptor<SyncInboxRecord>())
                .filter {
                    $0.stateRaw == "pending" &&
                    (retriesByRecordName[$0.id]?.nextRetryAt ?? .distantPast) <= now
                }
                .sorted { priority(for: $0.recordType) < priority(for: $1.recordType) }

            for inbox in pending {
                let inboxID = inbox.id
                do {
                    if try await apply(inbox, in: context) {
                        inbox.stateRaw = "applied"
                        if let retry = retriesByRecordName[inbox.id] {
                            if let stagedPath = retry.stagedAssetRelativePath {
                                _ = try StorageCleanupCoordinator.stage(
                                    location: .syncInboxStaging,
                                    relativePath: stagedPath,
                                    in: context
                                )
                            }
                            context.delete(retry)
                        }
                        madeProgress = true
                    }
                } catch {
                    context.rollback()
                    let retryContext = ModelContext(container)
                    guard let retryInbox = try retryContext.fetch(FetchDescriptor<SyncInboxRecord>()).first(where: { $0.id == inboxID }) else {
                        throw error
                    }
                    try recordRetry(for: retryInbox, error: error, in: retryContext)
                    try retryContext.save()
                    throw error
                }
            }
            if madeProgress {
                try context.save()
                StorageCleanupCoordinator.drainPendingCleanup(in: context)
            }
        }
        StorageCleanupCoordinator.drainPendingCleanup(in: context)
    }

    static func retryableUnstagedAssetRecordNames(container: ModelContainer) -> [String] {
        let context = ModelContext(container)
        let inboxes: [SyncInboxRecord]
        let retries: [SyncInboxRetryState]
        do {
            inboxes = try context.fetch(FetchDescriptor<SyncInboxRecord>())
            retries = try context.fetch(FetchDescriptor<SyncInboxRetryState>())
        } catch {
            AppLogger.sync.error("Failed to fetch inbox/retry states in retryableUnstagedAssetRecordNames: \(error.localizedDescription, privacy: .private)")
            return []
        }
        let retriesByRecordName = Dictionary(uniqueKeysWithValues: retries.map { ($0.recordName, $0) })
        let now = Date()
        return inboxes.compactMap { inbox in
            let retry = retriesByRecordName[inbox.id]
            let hasStagedAsset = retry?.stagedAssetRelativePath
                .flatMap(stagedAssetURL(for:))
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard inbox.recordType == CloudSyncRecordType.asset.rawValue,
                  (inbox.stateRaw == "pending" || inbox.stateRaw == "blocked"),
                  !hasStagedAsset,
                  (retry?.nextRetryAt ?? .distantPast) <= now else {
                return nil
            }
            return inbox.id
        }
    }

    private static func apply(_ inbox: SyncInboxRecord, in context: ModelContext) async throws -> Bool {
        guard let type = CloudSyncRecordType(rawValue: inbox.recordType) else {
            throw CloudSyncRecordCodecError.unsupportedRecordType(inbox.recordType)
        }

        switch type {
        case .generation:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncGenerationPayload.self, from: inbox.payloadData)
            let runtime = try SyncRuntimeStore.runtime(in: context)
            let remoteID = payload.generationID.uuidString.lowercased()
            runtime.generationID = remoteID
            let binding = try SyncAccountCoordinator.binding(in: context)
            binding.boundGenerationID = remoteID
            runtime.updatedAt = Date()
            return true

        case .folder:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncFolderPayload.self, from: inbox.payloadData)
            guard !payload.isSystem else { return true }
            guard !isTombstoned(kind: .folder, entityID: payload.folderID.uuidString, in: context) else { return true }
            let contentDigest = try SyncContentDigest.folder(
                id: payload.folderID,
                name: payload.name,
                sortOrder: payload.sortOrder
            )
            let folders = try context.fetch(FetchDescriptor<Folder>())
            let folder = folders.first(where: { $0.id == payload.folderID }) ?? {
                let folder = Folder(id: payload.folderID, name: payload.name, isSystem: false, sortOrder: payload.sortOrder)
                context.insert(folder)
                return folder
            }()
            guard shouldApply(
                id: "folder:\(payload.folderID.uuidString.lowercased())",
                kind: .folder,
                localEntityID: payload.folderID.uuidString.lowercased(),
                recordName: inbox.id,
                revision: payload.revision,
                modifiedAt: payload.modifiedAt,
                deviceID: payload.deviceID,
                contentDigest: contentDigest,
                in: context
            ) else { return true }
            folder.name = payload.name
            folder.sortOrder = payload.sortOrder
            folder.isSystem = false
            return true

        case .asset:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncAssetPayload.self, from: inbox.payloadData)
            guard !isTombstoned(kind: .book, entityID: payload.bookID.uuidString, in: context) else {
                return true
            }
            guard shouldInstallAsset(payload, in: context) else {
                return true
            }
            let assets = try context.fetch(FetchDescriptor<SyncAsset>())
            let matchingAsset = assets.first { $0.id == payload.assetID }
            let hasVerifiedAsset = matchingAsset.map { asset in
                guard asset.contentRevision >= payload.contentRevision,
                      asset.sha256Hex == payload.sha256Hex,
                      asset.localStateRaw == SyncAssetLocalState.verified.rawValue,
                      let relativePath = asset.localRelativePath,
                      StorageCleanupCoordinator.isSafeRelativePath(relativePath) else {
                    return false
                }
                let directory = payload.kind == .audio
                    ? StorageManager.shared.storyCastLibraryURL
                    : StorageManager.shared.coverArtDirectoryURL
                let fileURL = directory.appendingPathComponent(relativePath).standardizedFileURL
                let root = directory.standardizedFileURL
                guard fileURL.deletingLastPathComponent() == root else { return false }
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                return attrs?[.type] as? FileAttributeType == .typeRegular
            } ?? false
            if hasVerifiedAsset {
                return true
            }

            guard let retry = try existingRetryState(for: inbox.id, in: context),
                  let stagedPath = retry.stagedAssetRelativePath,
                  let stagedURL = stagedAssetURL(for: stagedPath),
                  FileManager.default.fileExists(atPath: stagedURL.path) else {
                return false
            }
            let installed = try await installAsset(payload: payload, temporaryURL: stagedURL, claimID: retry.claimID, in: context)
            upsertAsset(payload: payload, localFileName: installed.lastPathComponent, in: context)
            return true

        case .book:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncBookPayload.self, from: inbox.payloadData)
            guard !isTombstoned(kind: .book, entityID: payload.bookID.uuidString, in: context) else { return true }
            let contentDigest = try SyncContentDigest.book(
                id: payload.bookID,
                title: payload.title,
                author: payload.author,
                duration: payload.duration,
                folderID: payload.folderID,
                audioAssetID: payload.audioAssetID,
                audioAssetRevision: payload.audioAssetRevision ?? 1,
                coverArtAssetID: payload.coverArtAssetID,
                coverArtAssetRevision: payload.coverArtAssetRevision,
                chapterSetID: payload.chapterSetID
            )
            if isStale(
                id: "book:\(payload.bookID.uuidString.lowercased())",
                revision: payload.revision,
                modifiedAt: payload.modifiedAt,
                deviceID: payload.deviceID,
                contentDigest: contentDigest,
                in: context
            ) { return true }
            let assets = try context.fetch(FetchDescriptor<SyncAsset>())
            guard let audio = assets.first(where: {
                $0.id == payload.audioAssetID &&
                $0.contentRevision >= (payload.audioAssetRevision ?? 1) &&
                $0.localStateRaw == SyncAssetLocalState.verified.rawValue
            }), let audioFileName = audio.localRelativePath else { return false }
            let cover = payload.coverArtAssetID.flatMap { coverID in
                assets.first(where: {
                    $0.id == coverID && $0.localStateRaw == SyncAssetLocalState.verified.rawValue
                    && $0.contentRevision >= (payload.coverArtAssetRevision ?? 1)
                })
            }
            if payload.coverArtAssetID != nil, cover == nil { return false }

            let folders = try context.fetch(FetchDescriptor<Folder>())
            let targetFolder: Folder
            if let folderID = payload.folderID {
                if isTombstoned(kind: .folder, entityID: folderID.uuidString, in: context) {
                    targetFolder = try FolderService.stageUnfiledFolder(in: context)
                } else {
                    guard let folder = folders.first(where: { $0.id == folderID }) else { return false }
                    targetFolder = folder
                }
            } else {
                targetFolder = try FolderService.stageUnfiledFolder(in: context)
            }

            guard shouldApply(
                id: "book:\(payload.bookID.uuidString.lowercased())",
                kind: .book,
                localEntityID: payload.bookID.uuidString.lowercased(),
                recordName: inbox.id,
                revision: payload.revision,
                modifiedAt: payload.modifiedAt,
                deviceID: payload.deviceID,
                contentDigest: contentDigest,
                in: context
            ) else { return true }

            let books = try context.fetch(FetchDescriptor<Book>())
            let book = books.first(where: { $0.id == payload.bookID && !$0.isRemote }) ?? {
                let book = Book(
                    id: payload.bookID,
                    title: payload.title,
                    author: payload.author,
                    localFileName: audioFileName,
                    duration: payload.duration,
                    isImported: true,
                    folder: targetFolder,
                    coverArtFileName: cover?.localRelativePath
                )
                context.insert(book)
                return book
            }()
            book.title = payload.title
            book.author = payload.author
            book.duration = payload.duration
            book.localFileName = audioFileName
            book.coverArtFileName = cover?.localRelativePath
            book.folder = targetFolder
            book.isImported = true
            book.isRemote = false
            book.updateSearchFields()
            return true

        case .chapter:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncChapterPayload.self, from: inbox.payloadData)
            guard !isTombstoned(kind: .book, entityID: payload.bookID.uuidString, in: context) else { return true }
            let stateID = "chapter:\(payload.bookID.uuidString.lowercased()):\(payload.index)"
            let contentDigest = try SyncContentDigest.chapter(
                bookID: payload.bookID, chapterSetID: payload.chapterSetID, index: payload.index,
                title: payload.title, startTime: payload.startTime, endTime: payload.endTime,
                sourceRaw: payload.sourceRaw
            )
            if isStale(id: stateID, revision: payload.revision, modifiedAt: payload.modifiedAt,
                       deviceID: payload.deviceID, contentDigest: contentDigest, in: context) {
                return true
            }
            let books = try context.fetch(FetchDescriptor<Book>())
            guard let book = books.first(where: { $0.id == payload.bookID && !$0.isRemote }) else { return false }
            let chapters = book.chapters.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.title < $1.title
            }
            guard payload.index >= 0, payload.index <= chapters.count else { return false }
            guard shouldApply(
                id: stateID,
                kind: .chapter,
                localEntityID: "\(payload.bookID.uuidString.lowercased()):\(payload.index)",
                recordName: inbox.id,
                revision: payload.revision,
                modifiedAt: payload.modifiedAt,
                deviceID: payload.deviceID,
                contentDigest: contentDigest,
                in: context
            ) else { return true }
            let chapter: Chapter
            let titleMatches = chapters.filter { $0.title == payload.title && abs($0.startTime - payload.startTime) < 0.001 }
            if titleMatches.count == 1, let matched = titleMatches.first {
                chapter = matched
            } else if chapters.indices.contains(payload.index) {
                chapter = chapters[payload.index]
            } else {
                chapter = Chapter(
                    title: payload.title,
                    startTime: payload.startTime,
                    endTime: payload.endTime,
                    source: ChapterSource(rawValue: payload.sourceRaw) ?? .unknown,
                    book: book
                )
                context.insert(chapter)
            }
            chapter.title = payload.title
            chapter.startTime = payload.startTime
            chapter.endTime = payload.endTime
            chapter.source = ChapterSource(rawValue: payload.sourceRaw) ?? .unknown
            chapter.book = book
            return true

        case .progress:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncProgressPayload.self, from: inbox.payloadData)
            if isTombstoned(kind: .book, entityID: payload.action.bookID.uuidString, in: context) {
                return true
            }
            let books = try context.fetch(FetchDescriptor<Book>())
            guard let book = books.first(where: { $0.id == payload.action.bookID && !$0.isRemote }) else { return false }
            let heads = try context.fetch(FetchDescriptor<SyncProgressHead>())
            let existing = heads.first(where: { $0.id == inbox.id })
            if let existing {
                let current = action(from: existing)
                guard SyncProgressConflictResolver.isNewer(payload.action, than: current) else { return true }
                update(existing, with: payload.action)
            } else {
                context.insert(SyncProgressHead(
                    id: inbox.id,
                    bookID: payload.action.bookID,
                    deviceID: payload.action.deviceID,
                    actionID: payload.action.actionID,
                    position: payload.action.position,
                    actionAt: payload.action.actionAt,
                    sequence: payload.action.sequence,
                    actionKindRaw: payload.action.actionKind
                ))
            }
            let candidates = try context.fetch(FetchDescriptor<SyncProgressHead>())
                .filter { $0.bookID == payload.action.bookID }
                .map(action(from:))
            let winningAction = candidates.reduce(nil as SyncProgressAction?, { current, candidate in
                guard let current else { return candidate }
                return SyncProgressConflictResolver.winner(current, candidate)
            })
            if let winner = winningAction {
                book.lastPlaybackPosition = max(0, winner.position)
                book.lastPlayedDate = winner.actionAt
            }
            return true

        case .tombstone:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncTombstonePayload.self, from: inbox.payloadData)
            upsertTombstone(payload, in: context)
            var pendingCleanups = Set(try SyncDeletionCoordinator.discardReplicaState(
                entityKind: payload.entityKind,
                entityID: payload.entityID,
                in: context
            ))
            switch payload.entityKind {
            case .book:
                guard let bookID = UUID(uuidString: payload.entityID) else { return true }
                let books = try context.fetch(FetchDescriptor<Book>())
                if let book = books.first(where: { $0.id == bookID && !$0.isRemote }) {
                    if !book.localFileName.isEmpty {
                        pendingCleanups.insert(PendingFileCleanup(
                            location: .managedLibrary,
                            relativePath: book.localFileName
                        ))
                    }
                    if let coverArtFileName = book.coverArtFileName {
                        pendingCleanups.insert(PendingFileCleanup(
                            location: .coverArt,
                            relativePath: coverArtFileName
                        ))
                    }
                    context.delete(book)
                }
            case .folder:
                guard let folderID = UUID(uuidString: payload.entityID) else { return true }
                let folders = try context.fetch(FetchDescriptor<Folder>())
                if let folder = folders.first(where: { $0.id == folderID && !$0.isSystem }) {
                    let unfiled = try FolderService.stageUnfiledFolder(in: context)
                    for book in folder.books { book.folder = unfiled }
                    context.delete(folder)
                }
            case .generation, .chapter, .asset, .progress, .tombstone:
                break
            }
            for cleanup in pendingCleanups {
                _ = try StorageCleanupCoordinator.stage(
                    location: cleanup.location,
                    relativePath: cleanup.relativePath,
                    in: context
                )
            }
            return true
        }
    }

    private static func installAsset(
        payload: CloudSyncAssetPayload,
        temporaryURL: URL,
        claimID: UUID?,
        in context: ModelContext
    ) async throws -> URL {
        switch payload.kind {
        case .audio:
            try await StorageManager.shared.setupStoryCastLibraryDirectory()
        case .coverArt:
            try await StorageManager.shared.setupCoverArtDirectory()
        }

        let destination = try assetDestinationURL(for: payload, claimID: claimID, in: context)

        return try await Task.detached(priority: .utility) {
            let fingerprint = try SyncFileHasher.fingerprint(of: temporaryURL)
            guard fingerprint.byteCount == payload.byteCount, fingerprint.sha256Hex == payload.sha256Hex else {
                throw SyncInboxError.invalidAsset(recordName: payload.assetID.uuidString)
            }

            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                let existing = try SyncFileHasher.fingerprint(of: destination)
                if existing == fingerprint { return destination }
            }

            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".icloud-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: temporaryURL, to: staging)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
            return destination
        }.value
    }

    private static func assetDestinationURL(
        for payload: CloudSyncAssetPayload,
        claimID: UUID?,
        in context: ModelContext
    ) throws -> URL {
        guard let pathExtension = safePathExtension(payload.pathExtension) else {
            throw SyncInboxError.invalidAsset(recordName: payload.assetID.uuidString)
        }
        let directory = payload.kind == .audio
            ? StorageManager.shared.storyCastLibraryURL
            : StorageManager.shared.coverArtDirectoryURL
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let defaultName = "icloud-\(payload.assetID.uuidString.lowercased())\(suffix)"
        let fallbackName: String
        if let claimID {
            fallbackName = "icloud-sync-\(payload.assetID.uuidString.lowercased())-\(claimID.uuidString.prefix(8).lowercased())\(suffix)"
        } else {
            fallbackName = "icloud-sync-\(payload.assetID.uuidString.lowercased())\(suffix)"
        }
        let assets = try context.fetch(FetchDescriptor<SyncAsset>())
        let books = try context.fetch(FetchDescriptor<Book>())
        let existingPath = assets.first(where: { $0.id == payload.assetID })?.localRelativePath
        var candidateNames: [String] = []
        for candidateName in [existingPath, defaultName, fallbackName].compactMap({ $0 })
        where !candidateNames.contains(candidateName) {
            candidateNames.append(candidateName)
        }

        for candidateName in candidateNames where StorageCleanupCoordinator.isSafeRelativePath(candidateName) {
            let referencedByAnotherBook = books.contains { book in
                guard !book.isRemote, book.id != payload.bookID else { return false }
                switch payload.kind {
                case .audio:
                    return book.localFileName == candidateName
                case .coverArt:
                    return book.coverArtFileName == candidateName
                }
            }
            let referencedByAnotherAsset = assets.contains {
                $0.id != payload.assetID &&
                $0.kindRaw == payload.kind.rawValue &&
                $0.localRelativePath == candidateName
            }
            guard !referencedByAnotherBook, !referencedByAnotherAsset else { continue }
            return directory.appendingPathComponent(candidateName)
        }

        throw SyncInboxError.invalidAsset(recordName: payload.assetID.uuidString)
    }

    private static func upsertInbox(
        id: String,
        recordType: String,
        payloadData: Data,
        in context: ModelContext
    ) -> SyncInboxRecord {
        let records: [SyncInboxRecord]
        do {
            records = try context.fetch(FetchDescriptor<SyncInboxRecord>())
        } catch {
            AppLogger.sync.error("Failed to fetch SyncInboxRecord in upsertInbox: \(error.localizedDescription, privacy: .private)")
            records = []
        }
        if let existing = records.first(where: { $0.id == id }) {
            existing.recordType = recordType
            existing.payloadData = payloadData
            existing.receivedAt = Date()
            existing.stateRaw = "pending"
            return existing
        }
        let inbox = SyncInboxRecord(id: id, recordType: recordType, payloadData: payloadData)
        context.insert(inbox)
        return inbox
    }

    private static func safePathExtension(_ value: String) -> String? {
        let extensionValue = value.lowercased()
        guard extensionValue.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-")).contains($0)
        }) else {
            return nil
        }
        return extensionValue
    }

    private static var incomingAssetStagingDirectoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupportURL.appendingPathComponent("StoryCast/SyncInboxAssets", isDirectory: true)
    }

    private static func stageIncomingAsset(
        _ sourceURL: URL,
        for payload: CloudSyncAssetPayload
    ) async throws -> URL {
        guard let pathExtension = safePathExtension(payload.pathExtension) else {
            throw SyncInboxError.invalidAsset(recordName: payload.assetID.uuidString)
        }
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let destination = incomingAssetStagingDirectoryURL
            .appendingPathComponent("asset-\(payload.assetID.uuidString.lowercased())-\(payload.contentRevision)\(suffix)")

        return try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stagingURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".asset-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: stagingURL) }

            try manager.copyItem(at: sourceURL, to: stagingURL)
            if manager.fileExists(atPath: destination.path) {
                let attributes = try manager.attributesOfItem(atPath: destination.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw SyncInboxError.invalidAsset(recordName: payload.assetID.uuidString)
                }
                _ = try manager.replaceItemAt(destination, withItemAt: stagingURL)
            } else {
                try manager.moveItem(at: stagingURL, to: destination)
            }
            return destination
        }.value
    }

    private static func stagedAssetURL(for relativePath: String) -> URL? {
        guard StorageCleanupCoordinator.isSafeRelativePath(relativePath) else { return nil }
        let root = incomingAssetStagingDirectoryURL.standardizedFileURL
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == root else { return nil }
        return fileURL
    }

    private static func removeStagedAsset(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func clearRetryState(for recordName: String, in context: ModelContext) throws {
        let states = try context.fetch(FetchDescriptor<SyncInboxRetryState>())
        for state in states where state.recordName == recordName {
            if let stagedPath = state.stagedAssetRelativePath {
                _ = try StorageCleanupCoordinator.stage(
                    location: .syncInboxStaging,
                    relativePath: stagedPath,
                    in: context
                )
            }
            context.delete(state)
        }
    }

    private static func stageStaleRetryCleanup(for recordName: String, in context: ModelContext) throws {
        if let retry = try existingRetryState(for: recordName, in: context) {
            if let stagedPath = retry.stagedAssetRelativePath {
                _ = try StorageCleanupCoordinator.stage(
                    location: .syncInboxStaging,
                    relativePath: stagedPath,
                    in: context
                )
            }
            context.delete(retry)
        }
    }

    private static func updateBookAssetReferences(
        payload: CloudSyncAssetPayload,
        localFileName: String,
        in context: ModelContext
    ) {
        let books: [Book]
        do {
            books = try context.fetch(FetchDescriptor<Book>())
        } catch {
            AppLogger.sync.error("Failed to fetch books in updateBookAssetReferences: \(error.localizedDescription, privacy: .private)")
            return
        }
        for book in books where book.id == payload.bookID && !book.isRemote {
            switch payload.kind {
            case .audio:
                if book.localFileName != localFileName {
                    book.localFileName = localFileName
                    book.updateSearchFields()
                }
            case .coverArt:
                if book.coverArtFileName != localFileName {
                    book.coverArtFileName = localFileName
                }
            }
        }
    }

    private static func existingRetryState(
        for recordName: String,
        in context: ModelContext
    ) throws -> SyncInboxRetryState? {
        try context.fetch(FetchDescriptor<SyncInboxRetryState>()).first { $0.recordName == recordName }
    }

    private static func retryState(
        for inbox: SyncInboxRecord,
        in context: ModelContext
    ) throws -> SyncInboxRetryState {
        let fingerprint = SHA256.hash(data: inbox.payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let state = try existingRetryState(for: inbox.id, in: context) ?? {
            let state = SyncInboxRetryState(recordName: inbox.id, deliveryFingerprint: fingerprint)
            context.insert(state)
            return state
        }()
        if state.deliveryFingerprint != fingerprint {
            if let oldStagedPath = state.stagedAssetRelativePath {
                _ = try StorageCleanupCoordinator.stage(
                    location: .syncInboxStaging,
                    relativePath: oldStagedPath,
                    in: context
                )
            }
            state.deliveryFingerprint = fingerprint
            state.attemptCount = 0
            state.stagedAssetRelativePath = nil
            state.claimID = nil
        }
        return state
    }

    private static func recordRetry(
        for inbox: SyncInboxRecord,
        error: Error,
        in context: ModelContext
    ) throws {
        let state = try retryState(for: inbox, in: context)
        state.attemptCount += 1
        state.lastAttemptAt = Date()
        state.lastErrorMessage = error.localizedDescription
        state.nextRetryAt = Date().addingTimeInterval(retryDelay(for: state.attemptCount))
        state.updatedAt = Date()
        inbox.stateRaw = "pending"
    }

    private static func retryDelay(for attemptCount: Int) -> TimeInterval {
        min(pow(2, Double(max(0, attemptCount - 1))), 300)
    }

    private static func upsertAsset(
        payload: CloudSyncAssetPayload,
        localFileName: String,
        in context: ModelContext
    ) {
        let assets: [SyncAsset]
        do {
            assets = try context.fetch(FetchDescriptor<SyncAsset>())
        } catch {
            AppLogger.sync.error("Failed to fetch assets in upsertAsset: \(error.localizedDescription, privacy: .private)")
            return
        }
        let asset = assets.first(where: { $0.id == payload.assetID }) ?? {
            let asset = SyncAsset(
                id: payload.assetID,
                bookID: payload.bookID,
                kindRaw: payload.kind.rawValue,
                contentRevision: payload.contentRevision,
                originalFileName: payload.originalFileName,
                pathExtension: payload.pathExtension,
                contentTypeIdentifier: payload.contentTypeIdentifier,
                byteCount: payload.byteCount,
                sha256Hex: payload.sha256Hex
            )
            context.insert(asset)
            return asset
        }()
        asset.bookID = payload.bookID
        asset.kindRaw = payload.kind.rawValue
        asset.contentRevision = payload.contentRevision
        asset.originalFileName = payload.originalFileName
        asset.pathExtension = payload.pathExtension
        asset.contentTypeIdentifier = payload.contentTypeIdentifier
        asset.byteCount = payload.byteCount
        asset.sha256Hex = payload.sha256Hex
        asset.localRelativePath = localFileName
        asset.cloudRelativePath = payload.cloudRelativePath
        asset.localStateRaw = SyncAssetLocalState.verified.rawValue
        asset.cloudStateRaw = SyncAssetCloudState.published.rawValue
        asset.lastVerifiedAt = Date()
        asset.lastErrorMessage = nil
    }

    private static func shouldApply(
        id: String,
        kind: SyncEntityKind,
        localEntityID: String,
        recordName: String,
        revision: Int64,
        modifiedAt: Date,
        deviceID: String,
        contentDigest: String,
        in context: ModelContext
    ) -> Bool {
        let states: [SyncEntityState]
        do {
            states = try context.fetch(FetchDescriptor<SyncEntityState>())
        } catch {
            AppLogger.sync.error("Failed to fetch entity states in shouldApply: \(error.localizedDescription, privacy: .private)")
            return false
        }
        if let state = states.first(where: { $0.id == id }) {
            let decision = SyncVersionResolver.decide(
                localRevision: state.revision, localModifiedAt: state.modifiedAt,
                localDeviceID: state.deviceID, localDigest: state.contentDigest ?? "",
                remoteRevision: revision, remoteModifiedAt: modifiedAt,
                remoteDeviceID: deviceID, remoteDigest: contentDigest
            )
            if decision == .localWins {
                markForUpload(id: id, recordName: recordName, reason: "conflictWinner", in: context)
                return false
            }
            state.recordName = recordName
            state.revision = revision
            state.modifiedAt = modifiedAt
            state.deviceID = deviceID
            state.contentDigest = contentDigest
            removeUploadMarker(id: id, in: context)
            return true
        }
        context.insert(SyncEntityState(
            id: id,
            entityKindRaw: kind.rawValue,
            localEntityID: localEntityID,
            recordName: recordName,
            revision: revision,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            contentDigest: contentDigest
        ))
        return true
    }

    private static func isStale(
        id: String,
        revision: Int64,
        modifiedAt: Date,
        deviceID: String,
        contentDigest: String,
        in context: ModelContext
    ) -> Bool {
        let states: [SyncEntityState]
        do {
            states = try context.fetch(FetchDescriptor<SyncEntityState>())
        } catch {
            AppLogger.sync.error("Failed to fetch entity states in isStale: \(error.localizedDescription, privacy: .private)")
            return false
        }
        guard let state = states.first(where: { $0.id == id }) else { return false }
        let decision = SyncVersionResolver.decide(
            localRevision: state.revision, localModifiedAt: state.modifiedAt,
            localDeviceID: state.deviceID, localDigest: state.contentDigest ?? "",
            remoteRevision: revision, remoteModifiedAt: modifiedAt,
            remoteDeviceID: deviceID, remoteDigest: contentDigest
        )
        if decision == .localWins {
            markForUpload(id: id, recordName: state.recordName, reason: "staleCloudRecord", in: context)
            return true
        }
        return false
    }

    private static func shouldInstallAsset(_ payload: CloudSyncAssetPayload, in context: ModelContext) -> Bool {
        let assets: [SyncAsset]
        do {
            assets = try context.fetch(FetchDescriptor<SyncAsset>())
        } catch {
            AppLogger.sync.error("Failed to fetch assets in shouldInstallAsset: \(error.localizedDescription, privacy: .private)")
            return true
        }
        guard let local = assets.first(where: { $0.id == payload.assetID }) else { return true }
        if payload.contentRevision != local.contentRevision {
            if payload.contentRevision < local.contentRevision {
                local.cloudStateRaw = SyncAssetCloudState.notScheduled.rawValue
                return false
            }
            return true
        }
        if payload.sha256Hex == local.sha256Hex {
            let fileIsPresent: Bool
            if let relativePath = local.localRelativePath,
               StorageCleanupCoordinator.isSafeRelativePath(relativePath) {
                let directory = payload.kind == .audio
                    ? StorageManager.shared.storyCastLibraryURL
                    : StorageManager.shared.coverArtDirectoryURL
                let fileURL = directory.appendingPathComponent(relativePath).standardizedFileURL
                let root = directory.standardizedFileURL
                if fileURL.deletingLastPathComponent() == root,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   attrs[.type] as? FileAttributeType == .typeRegular {
                    fileIsPresent = true
                } else {
                    fileIsPresent = false
                }
            } else {
                fileIsPresent = false
            }
            if fileIsPresent {
                local.cloudStateRaw = SyncAssetCloudState.published.rawValue
                return false
            }
            return true
        }
        let localDate = local.lastVerifiedAt ?? .distantPast
        if payload.readyAt != localDate {
            if payload.readyAt < localDate { local.cloudStateRaw = SyncAssetCloudState.notScheduled.rawValue }
            return payload.readyAt > localDate
        }
        let remoteWins = payload.sha256Hex > local.sha256Hex
        if !remoteWins { local.cloudStateRaw = SyncAssetCloudState.notScheduled.rawValue }
        return remoteWins
    }

    private static func markForUpload(id: String, recordName: String, reason: String, in context: ModelContext) {
        let markers: [SyncReplicaUploadMarker]
        do {
            markers = try context.fetch(FetchDescriptor<SyncReplicaUploadMarker>())
        } catch {
            AppLogger.sync.error("Failed to fetch upload markers in markForUpload: \(error.localizedDescription, privacy: .private)")
            return
        }
        guard !markers.contains(where: { $0.id == id }) else { return }
        context.insert(SyncReplicaUploadMarker(id: id, recordName: recordName, reasonRaw: reason))
    }

    private static func removeUploadMarker(id: String, in context: ModelContext) {
        let markers: [SyncReplicaUploadMarker]
        do {
            markers = try context.fetch(FetchDescriptor<SyncReplicaUploadMarker>())
        } catch {
            AppLogger.sync.error("Failed to fetch upload markers in removeUploadMarker: \(error.localizedDescription, privacy: .private)")
            return
        }
        for marker in markers where marker.id == id { context.delete(marker) }
    }

    private static func isTombstoned(
        kind: SyncEntityKind,
        entityID: String,
        in context: ModelContext
    ) -> Bool {
        let normalizedID = entityID.lowercased()
        let tombstones: [SyncTombstone]
        do {
            tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        } catch {
            AppLogger.sync.error("Failed to fetch tombstones in isTombstoned: \(error.localizedDescription, privacy: .private)")
            return false
        }
        return tombstones.contains {
            $0.entityKindRaw == kind.rawValue && $0.entityID.lowercased() == normalizedID
        }
    }

    private static func action(from head: SyncProgressHead) -> SyncProgressAction {
        SyncProgressAction(
            bookID: head.bookID,
            deviceID: head.deviceID,
            actionID: head.actionID,
            position: head.position,
            actionAt: head.actionAt,
            sequence: head.sequence,
            actionKind: head.actionKindRaw
        )
    }

    private static func update(_ head: SyncProgressHead, with action: SyncProgressAction) {
        head.actionID = action.actionID
        head.position = action.position
        head.actionAt = action.actionAt
        head.sequence = action.sequence
        head.actionKindRaw = action.actionKind
    }

    private static func upsertTombstone(_ payload: CloudSyncTombstonePayload, in context: ModelContext) {
        let id = SyncRecordName.tombstone(kind: payload.entityKind, id: payload.entityID)
        let tombstones: [SyncTombstone]
        do {
            tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        } catch {
            AppLogger.sync.error("Failed to fetch tombstones in upsertTombstone: \(error.localizedDescription, privacy: .private)")
            return
        }
        if let existing = tombstones.first(where: { $0.id == id }) {
            guard payload.revision >= existing.revision else { return }
            existing.deletedAt = payload.deletedAt
            existing.revision = payload.revision
            existing.deviceID = payload.deviceID
            return
        }
        context.insert(SyncTombstone(
            id: id,
            entityKindRaw: payload.entityKind.rawValue,
            entityID: payload.entityID,
            deletedAt: payload.deletedAt,
            revision: payload.revision,
            deviceID: payload.deviceID
        ))
    }

    private static func priority(for recordType: String) -> Int {
        switch CloudSyncRecordType(rawValue: recordType) {
        case .tombstone: 0
        case .generation: 1
        case .folder: 2
        case .asset: 3
        case .book: 4
        case .chapter: 5
        case .progress: 6
        case nil: 99
        }
    }

    private static func entityKind(for type: CloudSyncRecordType) -> SyncEntityKind {
        switch type {
        case .generation: .generation
        case .book: .book
        case .folder: .folder
        case .chapter: .chapter
        case .asset: .asset
        case .progress: .progress
        case .tombstone: .tombstone
        }
    }
}
