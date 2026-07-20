import CryptoKit
import Foundation

/// Canonical hashes for the user-editable portion of sync records. Transport
/// fields such as revision, device ID, and modification date are deliberately
/// excluded so a planning pass only creates a new revision for real content
/// changes.
nonisolated enum SyncContentDigest {
    static func folder(id: UUID, name: String, sortOrder: Int) throws -> String {
        try digest(FolderContent(id: id, name: name, sortOrder: sortOrder))
    }

    static func book(
        id: UUID,
        title: String,
        author: String?,
        duration: Double,
        folderID: UUID?,
        audioAssetID: UUID,
        audioAssetRevision: Int64 = 1,
        coverArtAssetID: UUID?,
        coverArtAssetRevision: Int64? = nil,
        chapterSetID: UUID
    ) throws -> String {
        try digest(BookContent(
            id: id,
            title: title,
            author: author,
            duration: duration,
            folderID: folderID,
            audioAssetID: audioAssetID,
            audioAssetRevision: audioAssetRevision,
            coverArtAssetID: coverArtAssetID,
            coverArtAssetRevision: coverArtAssetRevision,
            chapterSetID: chapterSetID
        ))
    }

    static func chapter(
        bookID: UUID,
        chapterSetID: UUID,
        index: Int,
        title: String,
        startTime: Double,
        endTime: Double,
        sourceRaw: String
    ) throws -> String {
        try digest(ChapterContent(
            bookID: bookID,
            chapterSetID: chapterSetID,
            index: index,
            title: title,
            startTime: startTime,
            endTime: endTime,
            sourceRaw: sourceRaw
        ))
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct FolderContent: Encodable {
        let id: UUID
        let name: String
        let sortOrder: Int
    }

    private struct BookContent: Encodable {
        let id: UUID
        let title: String
        let author: String?
        let duration: Double
        let folderID: UUID?
        let audioAssetID: UUID
        let audioAssetRevision: Int64
        let coverArtAssetID: UUID?
        let coverArtAssetRevision: Int64?
        let chapterSetID: UUID
    }

    private struct ChapterContent: Encodable {
        let bookID: UUID
        let chapterSetID: UUID
        let index: Int
        let title: String
        let startTime: Double
        let endTime: Double
        let sourceRaw: String
    }
}
