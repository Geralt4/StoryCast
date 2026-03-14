import Foundation
import SwiftData
import os

/// SwiftData model representing a configured Audiobookshelf server.
/// The API token is stored in the iOS Keychain (via AudiobookshelfAuth);
/// only a non-sensitive reference is kept here.
@Model
nonisolated
final class ABSServer {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Base URL of the server, e.g. "https://abs.home.local:13378"
    var url: String
    var username: String
    /// The ABS user ID returned at login — used for progress endpoints.
    var userId: String?
    /// Default library ID for instant library loading.
    var defaultLibraryId: String?
    /// Server version string from login response, e.g. "2.4.3"
    var serverVersion: String?
    var isActive: Bool
    var lastSyncDate: Date?
    var createdAt: Date
    /// Normalised base URL with scheme and no trailing slash.
    /// Pre-computed at creation/update time for safe cross-actor access.
    var normalizedURL: String = ""

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        username: String,
        userId: String? = nil,
        defaultLibraryId: String? = nil,
        serverVersion: String? = nil,
        isActive: Bool = true,
        lastSyncDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.userId = userId
        self.defaultLibraryId = defaultLibraryId
        self.serverVersion = serverVersion
        self.isActive = isActive
        self.lastSyncDate = lastSyncDate
        self.createdAt = createdAt
        self.normalizedURL = Self.computeNormalizedURL(from: url)
    }

    /// Updates the URL and recomputes the normalizedURL.
    func updateURL(_ newURL: String) {
        url = newURL
        normalizedURL = Self.computeNormalizedURL(from: newURL)
    }

    /// Computes the normalized URL from a raw URL string.
    /// This is a nonisolated static function safe to call from any context.
    nonisolated static func computeNormalizedURL(from rawURL: String) -> String {
        do {
            return try AudiobookshelfURLValidator.normalizedBaseURLString(from: rawURL)
        } catch {
            AppLogger.network.debug("URL normalization failed, using trimmed raw URL: \(error.localizedDescription, privacy: .private)")
            return rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// Creates a snapshot of this server's data for safe cross-actor passing.
    func snapshot() -> ABSServerSnapshot {
        ABSServerSnapshot(
            id: id,
            name: name,
            url: url,
            normalizedURL: normalizedURL,
            username: username,
            userId: userId,
            defaultLibraryId: defaultLibraryId,
            serverVersion: serverVersion,
            isActive: isActive,
            lastSyncDate: lastSyncDate,
            createdAt: createdAt
        )
    }
}

/// A Sendable snapshot of ABSServer data for safe cross-actor passing.
/// Use this when you need to pass server information across isolation boundaries.
struct ABSServerSnapshot: Sendable {
    let id: UUID
    let name: String
    let url: String
    let normalizedURL: String
    let username: String
    let userId: String?
    let defaultLibraryId: String?
    let serverVersion: String?
    let isActive: Bool
    let lastSyncDate: Date?
    let createdAt: Date
}
