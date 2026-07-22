import Foundation
import SwiftData

enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Book.self, Chapter.self, Folder.self] }

    @Model
    final class Chapter {
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
    }

    @Model
    final class Book {
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
            id: UUID = UUID(), title: String, author: String? = nil,
            localFileName: String, duration: Double, lastPlaybackPosition: Double = 0,
            lastPlayedDate: Date? = nil, isImported: Bool = false,
            folder: Folder? = nil, coverArtFileName: String? = nil
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
    final class Folder {
        @Attribute(.unique) var id: UUID
        var name: String
        var isSystem: Bool
        var sortOrder: Int
        @Relationship(deleteRule: .nullify, inverse: \Book.folder) var books: [Book] = []

        init(id: UUID = UUID(), name: String, isSystem: Bool = false, sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.isSystem = isSystem
            self.sortOrder = sortOrder
        }
    }
}

/// Internal migration bridge for V1 stores. V2 introduced required fields
/// without schema-level defaults, so they must first be added as optionals.
enum SchemaV1MigrationBridge: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 1, 0)
    static var models: [any PersistentModel.Type] { [Book.self, Chapter.self, Folder.self, ABSServer.self] }

    @Model
    final class Chapter {
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
    }

    @Model
    final class Book {
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
        var isRemote: Bool?
        var remoteItemId: String?
        var remoteLibraryId: String?
        var serverId: UUID?
        var isDownloaded: Bool?
        var localCachePath: String?
        var lastSyncDate: Date?
        var normalizedTitle: String?
        var normalizedAuthor: String?
        var searchKey: String?

        init(
            id: UUID = UUID(), title: String, author: String? = nil,
            localFileName: String, duration: Double, lastPlaybackPosition: Double = 0,
            lastPlayedDate: Date? = nil, isImported: Bool = false,
            folder: Folder? = nil, coverArtFileName: String? = nil
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
    final class Folder {
        @Attribute(.unique) var id: UUID
        var name: String
        var isSystem: Bool
        var sortOrder: Int
        @Relationship(deleteRule: .nullify, inverse: \Book.folder) var books: [Book] = []

        init(id: UUID = UUID(), name: String, isSystem: Bool = false, sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.isSystem = isSystem
            self.sortOrder = sortOrder
        }
    }
}

enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Book.self, Chapter.self, Folder.self, ABSServer.self] }

    @Model
    final class Chapter {
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
    }

    @Model
    final class Book {
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
        private(set) var searchKey: String = ""

        init(
            id: UUID = UUID(), title: String, author: String? = nil,
            localFileName: String = "", duration: Double, lastPlaybackPosition: Double = 0,
            lastPlayedDate: Date? = nil, isImported: Bool = false,
            folder: Folder? = nil, coverArtFileName: String? = nil,
            isRemote: Bool = false, remoteItemId: String? = nil,
            remoteLibraryId: String? = nil, serverId: UUID? = nil,
            isDownloaded: Bool = false, localCachePath: String? = nil,
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
            searchKey = normalizedAuthor.isEmpty ? normalizedTitle : "\(normalizedTitle) | \(normalizedAuthor)"
        }

        private static func normalizeForSearch(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "" }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
        }
    }

    @Model
    final class Folder {
        @Attribute(.unique) var id: UUID
        var name: String
        var isSystem: Bool
        var sortOrder: Int
        @Relationship(deleteRule: .nullify, inverse: \Book.folder) var books: [Book] = []

        init(id: UUID = UUID(), name: String, isSystem: Bool = false, sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.isSystem = isSystem
            self.sortOrder = sortOrder
        }
    }
}

enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Book.self, Chapter.self, Folder.self, ABSServer.self]
    }
}

@Model
class SchemaV3Marker {
    @Attribute(.unique) var id: UUID
    var schemaVersion: Int

    init(id: UUID = UUID(), schemaVersion: Int = 3) {
        self.id = id
        self.schemaVersion = schemaVersion
    }
}

enum SchemaV3WithMarker: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV3.models + [SchemaV3Marker.self]
    }
}

enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV3WithMarker.models + [
            SyncRuntime.self, SyncEntityState.self, SyncAsset.self,
            SyncOutboxOperation.self, SyncInboxRecord.self, SyncProgressHead.self,
            SyncTombstone.self, SyncMigrationJournal.self
        ]
    }
}

/// Compatibility layout used by early V4 stores before `contentDigest` was
/// added to SyncEntityState without a schema-version bump.
enum SchemaV4Legacy: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV3WithMarker.models + [
            SyncRuntime.self, SyncEntityState.self, SyncAsset.self,
            SyncOutboxOperation.self, SyncInboxRecord.self, SyncProgressHead.self,
            SyncTombstone.self, SyncMigrationJournal.self
        ]
    }

    @Model
    final class SyncEntityState {
        @Attribute(.unique) var id: String
        var entityKindRaw: String
        var localEntityID: String
        var recordName: String
        var revision: Int64
        var modifiedAt: Date
        var deviceID: String
        var recordSystemFields: Data?

        init(
            id: String,
            entityKindRaw: String,
            localEntityID: String,
            recordName: String,
            revision: Int64 = 0,
            modifiedAt: Date = Date(),
            deviceID: String,
            recordSystemFields: Data? = nil
        ) {
            self.id = id
            self.entityKindRaw = entityKindRaw
            self.localEntityID = localEntityID
            self.recordName = recordName
            self.revision = revision
            self.modifiedAt = modifiedAt
            self.deviceID = deviceID
            self.recordSystemFields = recordSystemFields
        }
    }
}

enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV4.models + [
            SyncAccountBinding.self, SyncCloudRecordState.self,
            SyncReplicaUploadMarker.self, SyncAssetRetentionState.self
        ]
    }
}

enum SchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV5.models + [
            StorageCleanupJournalEntry.self, SyncLocalMutation.self,
            SyncInboxRetryState.self, ServerRemovalJournalEntry.self
        ]
    }
}

enum StoryCastMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            SchemaV1.self, SchemaV1MigrationBridge.self, SchemaV2.self,
            SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self
        ]
    }

    static var stages: [MigrationStage] {
        [migrateV1toBridge, migrateBridgeToV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
    }

    static let migrateV1toBridge = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV1MigrationBridge.self
    )
    static let migrateBridgeToV2 = MigrationStage.custom(
        fromVersion: SchemaV1MigrationBridge.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            let books = try context.fetch(FetchDescriptor<SchemaV1MigrationBridge.Book>())
            for book in books {
                let normalizedTitle = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .folding(options: .diacriticInsensitive, locale: .current)
                let normalizedAuthor = (book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .folding(options: .diacriticInsensitive, locale: .current)
                book.isRemote = false
                book.isDownloaded = false
                book.normalizedTitle = normalizedTitle
                book.normalizedAuthor = normalizedAuthor
                book.searchKey = normalizedAuthor.isEmpty ? normalizedTitle : "\(normalizedTitle) | \(normalizedAuthor)"
            }
            try context.save()
        },
        didMigrate: nil
    )
    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: SchemaV2.self, toVersion: SchemaV3.self,
        willMigrate: nil, didMigrate: { _ in }
    )
    static let migrateV3toV4 = MigrationStage.lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self)
    static let migrateV4toV5 = MigrationStage.lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self)
    static let migrateV5toV6 = MigrationStage.lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self)
}

/// Compatibility plan for build 3 stores created after the marker was introduced.
enum StoryCastMarkerV3MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV3WithMarker.self, SchemaV4.self, SchemaV5.self, SchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [migrateMarkerV3toV4, StoryCastMigrationPlan.migrateV4toV5, StoryCastMigrationPlan.migrateV5toV6]
    }

    static let migrateMarkerV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3WithMarker.self,
        toVersion: SchemaV4.self
    )
}

enum StoryCastLegacyV4MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV4Legacy.self, SchemaV5.self, SchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [migrateLegacyV4toV5, StoryCastMigrationPlan.migrateV5toV6]
    }

    static let migrateLegacyV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaV4Legacy.self,
        toVersion: SchemaV5.self
    )
}
