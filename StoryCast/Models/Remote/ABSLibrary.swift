import Foundation

// MARK: - Login / Authorize

nonisolated struct ABSLoginRequest: Encodable {
    let username: String
    let password: String
}

nonisolated struct ABSLoginResponse: Decodable {
    let user: ABSUser
    let userDefaultLibraryId: String?
    let serverSettings: ABSServerSettings?
}

nonisolated struct ABSUser: Decodable {
    let id: String
    let username: String
    let token: String
    let type: String?
}

nonisolated struct ABSServerSettings: Decodable {
    let version: String?
}

/// Response from /api/me endpoint (user info without nested wrapper)
nonisolated struct ABSUserResponse: Decodable {
    let id: String
    let username: String
    let token: String
    let type: String?
}

nonisolated struct ABSServerStatus: Decodable {
    let isInit: Bool
    let language: String?
}

// MARK: - Libraries

nonisolated struct ABSLibrariesResponse: Decodable {
    let libraries: [ABSLibrary]
}

nonisolated struct ABSLibrary: Codable, Identifiable {
    let id: String
    let name: String
    let mediaType: String   // "book" or "podcast"
    let displayOrder: Int?
    let icon: String?
    let createdAt: Double?
    let lastUpdate: Double?
}

// MARK: - Library Items (Books)

nonisolated struct ABSLibraryItemsResponse: Decodable {
    let results: [ABSLibraryItem]
    let total: Int
    let limit: Int
    let page: Int
}

nonisolated struct ABSLibraryItem: Codable, Identifiable {
    let id: String
    let libraryId: String
    let mediaType: String
    let media: ABSBookMedia
    let addedAt: Double?
    let updatedAt: Double?

    /// Convenience: book title from nested metadata.
    var title: String { media.metadata.title ?? "Untitled" }

    /// Convenience: author name from nested metadata.
    var authorName: String? { media.metadata.authorName }

    /// Convenience: total duration in seconds.
    var duration: Double { media.duration ?? 0 }
}

nonisolated struct ABSBookMedia: Codable {
    let metadata: ABSBookMetadata
    let coverPath: String?
    let duration: Double?
    let numTracks: Int?
    let numChapters: Int?
    let audioFiles: [ABSAudioFile]?
    let chapters: [ABSChapter]?
    let tracks: [ABSAudioTrack]?
}

nonisolated struct ABSBookMetadata: Codable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let description: String?
    let publishedYear: String?
    let publisher: String?
    let language: String?
    let isbn: String?
    let asin: String?
    let explicit: Bool?
    let abridged: Bool?
}

nonisolated struct ABSAudioFile: Codable {
    let index: Int?
    let ino: String?
    let metadata: ABSFileMetadata?
    let duration: Double?
    let bitRate: Int?
    let codec: String?
    let mimeType: String?
}

nonisolated struct ABSFileMetadata: Codable {
    let filename: String?
    let ext: String?
    let path: String?
    let size: Double?
}

nonisolated struct ABSChapter: Codable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
}

nonisolated struct ABSAudioTrack: Codable {
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let title: String?
    let contentUrl: String?
    let mimeType: String?
    let metadata: ABSFileMetadata?
}
