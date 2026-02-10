import Foundation
import SwiftData

// MARK: - Versioned Schema

/// Defines the initial v1.0 schema so that future model changes can be
/// migrated without data loss. Any post-v1.0 schema change should add a
/// new VersionedSchema (e.g. SchemaV2) and a corresponding MigrationPlan.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Book.self, Chapter.self, Folder.self]
    }
}

// MARK: - Chapter

enum ChapterSource: String, Codable, CaseIterable, Identifiable {
    case embedded
    case unknown

    var id: Self { self }

    var displayName: String {
        switch self {
        case .embedded: return "From file metadata"
        case .unknown: return "Unknown"
        }
    }
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

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        localFileName: String,
        duration: Double,
        lastPlaybackPosition: Double = 0.0,
        lastPlayedDate: Date? = nil,
        isImported: Bool = false,
        folder: Folder? = nil,
        coverArtFileName: String? = nil
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
