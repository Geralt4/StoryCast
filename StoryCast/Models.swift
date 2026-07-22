import Foundation
import SwiftData

enum ChapterSource: String, Codable, Identifiable {
    case embedded
    case unknown

    var id: Self { self }
}

struct DetectedChapter: Sendable {
    let title: String
    let startTime: Double
    let endTime: Double
    let source: ChapterSource
}

@Model
class Chapter {
    var title: String
    var startTime: Double
    var endTime: Double
    var source: ChapterSource
    var book: Book?

    init(title: String, startTime: Double, endTime: Double, source: ChapterSource = .embedded, book: Book? = nil) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.book = book
    }

    var isValid: Bool {
        startTime.isFinite && endTime.isFinite &&
        startTime >= 0 && endTime >= 0 &&
        endTime > startTime
    }
}

@Model
class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var localFileName: String
    var duration: Double
    var lastPlaybackPosition: Double
    var lastPlayedDate: Date?
    var isImported: Bool
    var coverArtFileName: String?
    @Relationship(deleteRule: .cascade, inverse: \Chapter.book) var chapters: [Chapter] = []
    var folder: Folder?
    var isRemote: Bool
    var remoteItemId: String?
    var remoteLibraryId: String?
    var serverId: UUID?
    var isDownloaded: Bool
    var localCachePath: String?
    var lastSyncDate: Date?
    private(set) var normalizedTitle: String = ""
    private(set) var normalizedAuthor: String = ""

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        localFileName: String = "",
        duration: Double,
        lastPlaybackPosition: Double = 0,
        lastPlayedDate: Date? = nil,
        isImported: Bool = false,
        folder: Folder? = nil,
        coverArtFileName: String? = nil,
        isRemote: Bool = false,
        remoteItemId: String? = nil,
        remoteLibraryId: String? = nil,
        serverId: UUID? = nil,
        isDownloaded: Bool = false,
        localCachePath: String? = nil,
        lastSyncDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.localFileName = localFileName
        self.duration = duration
        self.lastPlaybackPosition = lastPlaybackPosition
        self.lastPlayedDate = lastPlayedDate
        self.isImported = isImported
        self.folder = folder
        self.coverArtFileName = coverArtFileName
        self.isRemote = isRemote
        self.remoteItemId = remoteItemId
        self.remoteLibraryId = remoteLibraryId
        self.serverId = serverId
        self.isDownloaded = isDownloaded
        self.localCachePath = localCachePath
        self.lastSyncDate = lastSyncDate
        updateSearchFields()
    }

    func updateSearchFields() {
        normalizedTitle = Self.normalizeForSearch(title)
        normalizedAuthor = Self.normalizeForSearch(author)
    }

    static func normalizeForSearch(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    func matchesSearch(query: String) -> Bool {
        let normalizedQuery = Self.normalizeForSearch(query)
        guard !normalizedQuery.isEmpty else { return true }
        return normalizedTitle.contains(normalizedQuery) || normalizedAuthor.contains(normalizedQuery)
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@Model
class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var isSystem: Bool
    var sortOrder: Int
    @Relationship(deleteRule: .nullify, inverse: \Book.folder) var books: [Book] = []

    var bookCount: Int { books.count }

    init(id: UUID = UUID(), name: String, isSystem: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.sortOrder = sortOrder
    }
}

nonisolated enum CurrentSchema {
    static let version = SchemaV6.versionIdentifier
    static let versionString = "6.0.0"
    static let schemaName = "SchemaV6"
}
