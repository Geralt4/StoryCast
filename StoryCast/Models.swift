import Foundation
import SwiftData

// MARK: - Versioned Schema

/// v1.0 schema for future migrations.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Book.self, Chapter.self, Folder.self]
    }
}

// MARK: - Chapter

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

    /// A chapter is valid when its time range is non-negative, finite, and non-empty.
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
    
    // MARK: - Remote Book Properties
    var isRemote: Bool
    var remoteItemId: String?
    var remoteLibraryId: String?
    var serverId: UUID?
    var isDownloaded: Bool
    var localCachePath: String?
    var lastSyncDate: Date?
    
    // MARK: - Cached Search Fields
    // Normalized fields for efficient search (updated when title/author changes)
    private(set) var normalizedTitle: String = ""
    private(set) var normalizedAuthor: String = ""

    func updateSearchFields() {
        normalizedTitle = Self.normalizeForSearch(title)
        normalizedAuthor = Self.normalizeForSearch(author)
    }
    
    static func normalizeForSearch(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }
    
    func matchesSearch(query: String) -> Bool {
        let normalizedQuery = Self.normalizeForSearch(query)
        guard !normalizedQuery.isEmpty else { return true }
        return normalizedTitle.contains(normalizedQuery) || 
               normalizedAuthor.contains(normalizedQuery)
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        localFileName: String = "",
        duration: Double,
        lastPlaybackPosition: Double = 0.0,
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
        self.updateSearchFields()
    }
    
    /// A book is valid when its title is non-empty after trimming whitespace.
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

    var bookCount: Int {
        books.count
    }

    init(id: UUID = UUID(), name: String, isSystem: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.sortOrder = sortOrder
    }
}

// MARK: - Schema V2 (Remote Books Support)

enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    
    static var models: [any PersistentModel.Type] {
        [Book.self, Chapter.self, Folder.self, ABSServer.self]
    }
}

// MARK: - Schema V3 (SearchKey Removal)

enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    
    static var models: [any PersistentModel.Type] {
        [Book.self, Chapter.self, Folder.self, ABSServer.self]
    }
}

// MARK: - Migration Plan

enum StoryCastMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }
    
    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }
    
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { _ in }
    )
    
    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self,
        willMigrate: nil,
        didMigrate: { _ in }
    )
}
