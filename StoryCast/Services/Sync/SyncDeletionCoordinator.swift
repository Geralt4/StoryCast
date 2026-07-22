import Foundation
import SwiftData

struct PendingFileCleanup: Sendable, Hashable {
    let location: CleanupLocation
    let relativePath: String
}

/// Removes local sync sidecars and supersedes unsent work before a tombstone is
/// published or applied. The tombstone itself remains durable so an offline
/// device cannot recreate the deleted entity later.
@MainActor
enum SyncDeletionCoordinator {
    static func discardReplicaState(
        entityKind: SyncEntityKind,
        entityID: String,
        in context: ModelContext
    ) throws -> [PendingFileCleanup] {
        let normalizedID = entityID.lowercased()
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())

        switch entityKind {
        case .book:
            guard let bookID = UUID(uuidString: entityID) else { return [] }
            let (assetRecordPrefixes, pendingCleanups) = try discardAssets(for: bookID, in: context)
            let bookRecordName = SyncRecordName.book(bookID)
            let chapterPrefix = "chapter/\(normalizedID)/"
            let progressPrefix = "progress/\(normalizedID)/"

            for operation in operations where operation.stateRaw != "sent" {
                let isBookOperation = operation.subjectID == bookRecordName
                let isChapterOperation = operation.subjectID.hasPrefix(chapterPrefix)
                let isProgressOperation = operation.subjectID.hasPrefix(progressPrefix)
                let assetPayloadMatchesBook = operation.payloadData.flatMap {
                    try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetPayload.self, from: $0)
                }?.bookID == bookID
                let isAssetOperation = assetRecordPrefixes.contains { operation.subjectID.hasPrefix($0) }
                    || assetPayloadMatchesBook
                if isBookOperation || isChapterOperation || isProgressOperation || isAssetOperation {
                    operation.stateRaw = "cancelled"
                    operation.nextRetryAt = nil
                    operation.lastErrorMessage = nil
                }
            }

            let progressHeads = try context.fetch(FetchDescriptor<SyncProgressHead>())
            for head in progressHeads where head.bookID == bookID {
                context.delete(head)
            }

            let states = try context.fetch(FetchDescriptor<SyncEntityState>())
            for state in states where
                state.recordName == bookRecordName ||
                state.recordName.hasPrefix(chapterPrefix) ||
                state.recordName.hasPrefix(progressPrefix) ||
                assetRecordPrefixes.contains(where: { state.recordName.hasPrefix($0) }) {
                context.delete(state)
            }

            return pendingCleanups

        case .folder:
            guard let folderID = UUID(uuidString: entityID) else { return [] }
            let recordName = SyncRecordName.folder(folderID)
            for operation in operations where operation.subjectID == recordName && operation.stateRaw != "sent" {
                operation.stateRaw = "cancelled"
                operation.nextRetryAt = nil
                operation.lastErrorMessage = nil
            }
            let states = try context.fetch(FetchDescriptor<SyncEntityState>())
            for state in states where state.recordName == recordName {
                context.delete(state)
            }

        case .generation, .chapter, .asset, .progress, .tombstone:
            break
        }

        return []
    }

    private static func discardAssets(for bookID: UUID, in context: ModelContext) throws -> ([String], [PendingFileCleanup]) {
        let assets = try context.fetch(FetchDescriptor<SyncAsset>()).filter { $0.bookID == bookID }
        let prefixes = assets.map { "asset/\($0.id.uuidString.lowercased())/" }
        var pendingCleanups: [PendingFileCleanup] = []
        for asset in assets {
            if let relativePath = asset.localRelativePath {
                let isCoverArt = asset.kindRaw == SyncAssetKind.coverArt.rawValue
                pendingCleanups.append(PendingFileCleanup(
                    location: isCoverArt ? .coverArt : .managedLibrary,
                    relativePath: relativePath
                ))
            }
            context.delete(asset)
        }
        return (prefixes, pendingCleanups)
    }
}
