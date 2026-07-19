import CloudKit
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
            } else {
                guard let temporaryURL = CloudSyncRecordCodec.assetFileURL(from: record) else {
                    inbox.stateRaw = "blocked"
                    try context.save()
                    throw SyncInboxError.missingAsset(recordName: record.recordID.recordName)
                }
                let installed = try await installAsset(payload: payload, temporaryURL: temporaryURL)
                upsertAsset(payload: payload, localFileName: installed.lastPathComponent, in: context)
                inbox.stateRaw = "applied"
            }
        }

        try context.save()
        if drainAfterStaging {
            try drain(container: container)
        }
    }

    static func drain(container: ModelContainer) throws {
        let context = ModelContext(container)
        var madeProgress = true

        while madeProgress {
            madeProgress = false
            let pending = try context.fetch(FetchDescriptor<SyncInboxRecord>())
                .filter { $0.stateRaw == "pending" }
                .sorted { priority(for: $0.recordType) < priority(for: $1.recordType) }

            for inbox in pending {
                do {
                    if try apply(inbox, in: context) {
                        inbox.stateRaw = "applied"
                        madeProgress = true
                    }
                } catch {
                    inbox.stateRaw = "blocked"
                    throw error
                }
            }
            if madeProgress { try context.save() }
        }
    }

    private static func apply(_ inbox: SyncInboxRecord, in context: ModelContext) throws -> Bool {
        guard let type = CloudSyncRecordType(rawValue: inbox.recordType) else {
            throw CloudSyncRecordCodecError.unsupportedRecordType(inbox.recordType)
        }

        switch type {
        case .generation:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncGenerationPayload.self, from: inbox.payloadData)
            let runtime = try SyncRuntimeStore.runtime(in: context)
            let remoteID = payload.generationID.uuidString.lowercased()
            if let localID = runtime.generationID, localID != remoteID {
                throw SyncInboxError.generationMismatch(local: localID, remote: remoteID)
            }
            runtime.generationID = remoteID
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
                coverArtAssetID: payload.coverArtAssetID,
                chapterSetID: payload.chapterSetID
            )
            if isStale(
                id: "book:\(payload.bookID.uuidString.lowercased())",
                revision: payload.revision,
                modifiedAt: payload.modifiedAt,
                in: context
            ) { return true }
            let assets = try context.fetch(FetchDescriptor<SyncAsset>())
            guard let audio = assets.first(where: {
                $0.id == payload.audioAssetID && $0.localStateRaw == SyncAssetLocalState.verified.rawValue
            }), let audioFileName = audio.localRelativePath else { return false }
            let cover = payload.coverArtAssetID.flatMap { coverID in
                assets.first(where: {
                    $0.id == coverID && $0.localStateRaw == SyncAssetLocalState.verified.rawValue
                })
            }
            if payload.coverArtAssetID != nil, cover == nil { return false }

            let folders = try context.fetch(FetchDescriptor<Folder>())
            let targetFolder: Folder
            if let folderID = payload.folderID {
                if isTombstoned(kind: .folder, entityID: folderID.uuidString, in: context) {
                    targetFolder = try FolderService.resolveUnfiledFolder(in: context)
                } else {
                    guard let folder = folders.first(where: { $0.id == folderID }) else { return false }
                    targetFolder = folder
                }
            } else {
                targetFolder = try FolderService.resolveUnfiledFolder(in: context)
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
            if isStale(id: stateID, revision: payload.revision, modifiedAt: payload.modifiedAt, in: context) {
                return true
            }
            let books = try context.fetch(FetchDescriptor<Book>())
            guard let book = books.first(where: { $0.id == payload.bookID && !$0.isRemote }) else { return false }
            let chapters = book.chapters.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.title < $1.title
            }
            guard payload.index >= 0, payload.index <= chapters.count else { return false }
            let contentDigest = try SyncContentDigest.chapter(
                bookID: payload.bookID,
                chapterSetID: payload.chapterSetID,
                index: payload.index,
                title: payload.title,
                startTime: payload.startTime,
                endTime: payload.endTime,
                sourceRaw: payload.sourceRaw
            )
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
            if chapters.indices.contains(payload.index) {
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
            try SyncDeletionCoordinator.discardReplicaState(
                entityKind: payload.entityKind,
                entityID: payload.entityID,
                in: context
            )
            switch payload.entityKind {
            case .book:
                guard let bookID = UUID(uuidString: payload.entityID) else { return true }
                let books = try context.fetch(FetchDescriptor<Book>())
                if let book = books.first(where: { $0.id == bookID && !$0.isRemote }) {
                    let audioURL = StorageManager.shared.storyCastLibraryURL.appendingPathComponent(book.localFileName)
                    let coverURL = book.coverArtFileName.map { StorageManager.shared.coverArtDirectoryURL.appendingPathComponent($0) }
                    context.delete(book)
                    try? FileManager.default.removeItem(at: audioURL)
                    if let coverURL { try? FileManager.default.removeItem(at: coverURL) }
                }
            case .folder:
                guard let folderID = UUID(uuidString: payload.entityID) else { return true }
                let folders = try context.fetch(FetchDescriptor<Folder>())
                if let folder = folders.first(where: { $0.id == folderID && !$0.isSystem }) {
                    let unfiled = try FolderService.resolveUnfiledFolder(in: context)
                    for book in folder.books { book.folder = unfiled }
                    context.delete(folder)
                }
            case .generation, .chapter, .asset, .progress, .tombstone:
                break
            }
            return true
        }
    }

    private static func installAsset(payload: CloudSyncAssetPayload, temporaryURL: URL) async throws -> URL {
        switch payload.kind {
        case .audio:
            try await StorageManager.shared.setupStoryCastLibraryDirectory()
        case .coverArt:
            try await StorageManager.shared.setupCoverArtDirectory()
        }

        let directory = payload.kind == .audio
            ? StorageManager.shared.storyCastLibraryURL
            : StorageManager.shared.coverArtDirectoryURL
        let suffix = payload.pathExtension.isEmpty ? "" : ".\(payload.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent("icloud-\(payload.assetID.uuidString.lowercased())\(suffix)")

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

            let staging = directory.appendingPathComponent(".icloud-\(UUID().uuidString).tmp")
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

    private static func upsertInbox(
        id: String,
        recordType: String,
        payloadData: Data,
        in context: ModelContext
    ) -> SyncInboxRecord {
        let records = (try? context.fetch(FetchDescriptor<SyncInboxRecord>())) ?? []
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

    private static func upsertAsset(
        payload: CloudSyncAssetPayload,
        localFileName: String,
        in context: ModelContext
    ) {
        let assets = (try? context.fetch(FetchDescriptor<SyncAsset>())) ?? []
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
        let states = (try? context.fetch(FetchDescriptor<SyncEntityState>())) ?? []
        if let state = states.first(where: { $0.id == id }) {
            if revision < state.revision { return false }
            if revision == state.revision, modifiedAt < state.modifiedAt { return false }
            state.recordName = recordName
            state.revision = revision
            state.modifiedAt = modifiedAt
            state.deviceID = deviceID
            state.contentDigest = contentDigest
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
        in context: ModelContext
    ) -> Bool {
        let states = (try? context.fetch(FetchDescriptor<SyncEntityState>())) ?? []
        guard let state = states.first(where: { $0.id == id }) else { return false }
        if revision != state.revision { return revision < state.revision }
        return modifiedAt < state.modifiedAt
    }

    private static func isTombstoned(
        kind: SyncEntityKind,
        entityID: String,
        in context: ModelContext
    ) -> Bool {
        let normalizedID = entityID.lowercased()
        let tombstones = (try? context.fetch(FetchDescriptor<SyncTombstone>())) ?? []
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
        let tombstones = (try? context.fetch(FetchDescriptor<SyncTombstone>())) ?? []
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
        case .generation: 0
        case .folder: 1
        case .asset: 2
        case .book: 3
        case .chapter: 4
        case .progress: 5
        case .tombstone: 6
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
