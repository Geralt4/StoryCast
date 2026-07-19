import Foundation

nonisolated enum SyncMode: String, Codable, Sendable {
    case disabled
    case enabled
}

nonisolated enum SyncActivity: Equatable, Sendable {
    case disabled
    case preparing
    case syncing
    case waiting(reason: String)
    case idle
    case failed(message: String)
}

nonisolated struct SyncStatus: Equatable, Sendable {
    let mode: SyncMode
    let activity: SyncActivity
    let lastSuccessfulSyncAt: Date?

    static let disabled = SyncStatus(mode: .disabled, activity: .disabled, lastSuccessfulSyncAt: nil)
}

nonisolated enum SyncEntityKind: String, Codable, Sendable {
    case generation
    case book
    case folder
    case chapter
    case asset
    case progress
    case tombstone
}

nonisolated enum SyncOutboxKind: String, Codable, Sendable {
    case saveRecord
    case deleteRecord
    case uploadAsset
    case deleteAsset
}

nonisolated enum SyncAssetKind: String, Codable, Sendable {
    case audio
    case coverArt
}

nonisolated enum SyncAssetLocalState: String, Codable, Sendable {
    case missing
    case queuedForDownload
    case downloading
    case verifying
    case verified
    case blocked
    case corrupt
}

nonisolated enum SyncAssetCloudState: String, Codable, Sendable {
    case notScheduled
    case queuedForUpload
    case uploading
    case awaitingConfirmation
    case published
    case queuedForDeletion
    case deleting
    case deleted
    case blocked
}

/// A device-owned progress update. CloudKit stores one head per device so a
/// later action can be selected deterministically without record conflicts.
nonisolated struct SyncProgressAction: Codable, Equatable, Sendable {
    let bookID: UUID
    let deviceID: String
    let actionID: UUID
    let position: Double
    let actionAt: Date
    let sequence: Int64
    let actionKind: String
}

nonisolated enum SyncProgressConflictResolver {
    static func winner(_ lhs: SyncProgressAction, _ rhs: SyncProgressAction) -> SyncProgressAction {
        isNewer(lhs, than: rhs) ? lhs : rhs
    }

    static func isNewer(_ lhs: SyncProgressAction, than rhs: SyncProgressAction) -> Bool {
        if lhs.actionAt != rhs.actionAt {
            return lhs.actionAt > rhs.actionAt
        }
        if lhs.sequence != rhs.sequence {
            return lhs.sequence > rhs.sequence
        }
        return lhs.actionID.uuidString > rhs.actionID.uuidString
    }
}

/// Stable record names prevent filenames, display titles, and Audiobookshelf
/// identifiers from becoming synchronization identities.
nonisolated enum SyncRecordName {
    static func generation() -> String { "generation" }
    static func book(_ bookID: UUID) -> String { "book/\(bookID.uuidString.lowercased())" }
    static func folder(_ folderID: UUID) -> String { "folder/\(folderID.uuidString.lowercased())" }
    static func chapter(bookID: UUID, chapterSetID: UUID, index: Int) -> String {
        "chapter/\(bookID.uuidString.lowercased())/\(chapterSetID.uuidString.lowercased())/\(index)"
    }
    static func asset(_ assetID: UUID, revision: Int64) -> String {
        "asset/\(assetID.uuidString.lowercased())/\(revision)"
    }
    static func progress(bookID: UUID, deviceID: String) -> String {
        "progress/\(bookID.uuidString.lowercased())/\(deviceID)"
    }
    static func tombstone(kind: SyncEntityKind, id: String) -> String {
        "tombstone/\(kind.rawValue)/\(id)"
    }
}

/// The only representation of a `Book` eligible for CloudKit encoding. It
/// deliberately omits all Audiobookshelf and device-cache properties.
nonisolated struct SyncBookSnapshot: Codable, Equatable, Sendable {
    let bookID: UUID
    let title: String
    let author: String?
    let duration: Double
    let folderID: UUID?
    let localFileName: String
    let coverArtFileName: String?
    let lastPlaybackPosition: Double
    let lastPlayedDate: Date?

    @MainActor
    init?(book: Book) {
        let localFileName = book.localFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !book.isRemote, !localFileName.isEmpty else {
            return nil
        }
        self.bookID = book.id
        self.title = book.title
        self.author = book.author
        self.duration = book.duration
        self.folderID = book.folder?.isSystem == false ? book.folder?.id : nil
        self.localFileName = localFileName
        self.coverArtFileName = book.coverArtFileName
        self.lastPlaybackPosition = book.lastPlaybackPosition
        self.lastPlayedDate = book.lastPlayedDate
    }
}
