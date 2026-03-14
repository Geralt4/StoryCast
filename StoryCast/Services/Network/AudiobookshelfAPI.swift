import Foundation
import os
#if os(iOS)
import UIKit
#endif

struct AuthenticatedStream: Sendable {
    let url: URL
    let headers: [String: String]

    func makeRequest() -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

/// Central API client for all Audiobookshelf server communication.
/// All methods are `async throws` and run on the calling actor.
/// Authentication tokens are fetched from `AudiobookshelfAuth` (Keychain).
actor AudiobookshelfAPI {
    static let shared = AudiobookshelfAPI()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        // ABS timestamps are milliseconds-since-epoch doubles, not ISO8601 strings,
        // so we leave dateDecodingStrategy at default and handle them manually.
    }

    private func ensureNetworkConnected() async throws {
        guard await NetworkMonitor.shared.isConnected else {
            throw APIError.serverUnreachable
        }
    }

    // MARK: - Server Health

    /// Checks whether the server is reachable and initialised.
    func checkServerStatus(baseURL: String) async throws {
        let url = try makeURL(base: baseURL, path: "/status")
        let (data, response) = try await performRequest(URLRequest(url: url))
        try validateResponse(response, data: data)
        let status = try decode(ABSServerStatus.self, from: data)
        guard status.isInit else {
            throw APIError.serverNotInitialized
        }
    }

    // MARK: - Authentication

    /// Logs in with username/password and returns the user token.
    func login(baseURL: String, username: String, password: String) async throws -> ABSLoginResponse {
        let url = try makeURL(base: baseURL, path: "/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ABSLoginRequest(username: username, password: password))

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        return try decode(ABSLoginResponse.self, from: data)
    }

    /// Validates a stored token and returns the current user info.
    func authorize(baseURL: String, token: String) async throws -> ABSUserResponse {
        let url = try makeURL(base: baseURL, path: "/api/me")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        return try decode(ABSUserResponse.self, from: data)
    }

    // MARK: - Libraries

    /// Returns all libraries the authenticated user can access.
    func fetchLibraries(baseURL: String, token: String) async throws -> [ABSLibrary] {
        try await ensureNetworkConnected()
        let normalizedBaseURL = try normalizedBaseURLString(from: baseURL)
        let url = try makeURL(base: normalizedBaseURL, path: "/api/libraries")
        let request = authorizedRequest(url: url, token: token)
        do {
            let (data, response) = try await performRequest(request)
            try validateResponse(response, data: data)
            let result = try decode(ABSLibrariesResponse.self, from: data)
            return result.libraries.filter { $0.mediaType == "book" }
        } catch APIError.unauthorized {
            await handleUnauthorized(for: normalizedBaseURL)
            throw APIError.unauthorized
        }
    }

    // MARK: - Library Items

    /// Fetches a page of library items (books) from the given library.
    func fetchLibraryItems(
        baseURL: String,
        token: String,
        libraryId: String,
        page: Int = 0,
        limit: Int = 50,
        sort: String = "media.metadata.title"
    ) async throws -> ABSLibraryItemsResponse {
        try await ensureNetworkConnected()
        let normalizedBaseURL = try normalizedBaseURLString(from: baseURL)
        let url = try makeURL(base: normalizedBaseURL, path: "/api/libraries/\(libraryId)/items")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "minified", value: "0")
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        let request = authorizedRequest(url: url, token: token)
        do {
            let (data, response) = try await performRequest(request)
            try validateResponse(response, data: data)
            return try decode(ABSLibraryItemsResponse.self, from: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: normalizedBaseURL)
            throw APIError.unauthorized
        }
    }

    /// Fetches full detail for a single library item, including chapters and tracks.
    func fetchLibraryItem(
        baseURL: String,
        token: String,
        itemId: String
    ) async throws -> ABSLibraryItem {
        let normalizedBaseURL = try normalizedBaseURLString(from: baseURL)
        let url = try makeURL(base: normalizedBaseURL, path: "/api/items/\(itemId)")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "expanded", value: "1"),
            URLQueryItem(name: "include", value: "progress")
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        let request = authorizedRequest(url: url, token: token)
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        return try decode(ABSLibraryItem.self, from: data)
    }

    // MARK: - Playback Sessions

    /// Opens a playback session for the given item and returns streaming track info.
    func startPlaybackSession(
        baseURL: String,
        token: String,
        itemId: String
    ) async throws -> ABSPlaybackSession {
        let url = try makeURL(base: baseURL, path: "/api/items/\(itemId)/play")
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(await ABSPlayRequest.makeDefault())

        do {
            let (data, response) = try await performRequest(request)
            try validateResponse(response, data: data)
            return try decode(ABSPlaybackSession.self, from: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: baseURL)
            throw APIError.unauthorized
        }
    }

    /// Syncs playback progress for an active session.
    func syncSession(
        baseURL: String,
        token: String,
        sessionId: String,
        currentTime: Double,
        timeListened: Double,
        duration: Double
    ) async throws {
        let url = try makeURL(base: baseURL, path: "/api/session/\(sessionId)/sync")
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ABSSessionSyncRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        )
        do {
            let (data, response) = try await performRequest(request)
            try validateResponse(response, data: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: baseURL)
            throw APIError.unauthorized
        }
    }

    /// Closes an active playback session with a final progress sync.
    func closeSession(
        baseURL: String,
        token: String,
        sessionId: String,
        currentTime: Double,
        timeListened: Double,
        duration: Double
    ) async throws {
        let url = try makeURL(base: baseURL, path: "/api/session/\(sessionId)/close")
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ABSSessionSyncRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        )
        do {
            let (data, response) = try await performRequest(request)
            // 404 is acceptable here — session may have already expired on the server.
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return }
            try validateResponse(response, data: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: baseURL)
            throw APIError.unauthorized
        }
    }

    // MARK: - Progress

    /// Fetches the user's progress for a specific library item.
    func fetchProgress(
        baseURL: String,
        token: String,
        itemId: String
    ) async throws -> ABSMediaProgress? {
        let url = try makeURL(base: baseURL, path: "/api/me/progress/\(itemId)")
        let request = authorizedRequest(url: url, token: token)
        do {
            let (data, response) = try await performRequest(request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
            try validateResponse(response, data: data)
            return try decode(ABSMediaProgress.self, from: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: baseURL)
            throw APIError.unauthorized
        }
    }

    /// Updates progress for a library item directly (non-session).
    func updateProgress(
        baseURL: String,
        token: String,
        itemId: String,
        currentTime: Double,
        duration: Double,
        isFinished: Bool
    ) async throws {
        let url = try makeURL(base: baseURL, path: "/api/me/progress/\(itemId)")
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let progress = duration > 0 ? min(1.0, max(0.0, currentTime / duration)) : 0
        request.httpBody = try JSONEncoder().encode(
            ABSProgressUpdateRequest(
                duration: duration,
                progress: progress,
                currentTime: currentTime,
                isFinished: isFinished
            )
        )
        do {
            let (data, response) = try await performRequest(request)
            try validateResponse(response, data: data)
        } catch APIError.unauthorized {
            await handleUnauthorized(for: baseURL)
            throw APIError.unauthorized
        }
    }

    // MARK: - Cover Art

    /// Constructs the URL for a book's cover art (using Bearer token in Authorization header).
    func coverArtURL(baseURL: String, token: String, itemId: String, size: Int = 400) -> URL? {
        do {
            let url = try makeURL(base: baseURL, path: "/api/items/\(itemId)/cover")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "width", value: "\(size)"),
                URLQueryItem(name: "height", value: "\(size)"),
                URLQueryItem(name: "format", value: "jpeg")
            ]
            return components?.url
        } catch {
            AppLogger.network.debug("Could not construct cover art URL for item \(itemId): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Downloads cover art data for a library item.
    func fetchCoverArt(baseURL: String, token: String, itemId: String, size: Int = 400) async throws -> Data {
        guard let url = coverArtURL(baseURL: baseURL, token: token, itemId: itemId, size: size) else {
            throw APIError.invalidURL
        }
        let request = authorizedRequest(url: url, token: token)
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        return data
    }

    // MARK: - Streaming URL

    /// Builds a validated streaming URL for an audio track.
    func streamingURL(baseURL: String, contentUrl: String) throws -> URL {
        do {
            return try AudiobookshelfURLValidator.validatedStreamingURL(baseURL: baseURL, contentURL: contentUrl)
        } catch {
            AppLogger.network.warning("Blocked streaming URL for \(baseURL, privacy: .private): \(contentUrl, privacy: .private)")
            throw error
        }
    }

    func authenticatedStream(baseURL: String, token: String, contentUrl: String) throws -> AuthenticatedStream {
        let url = try streamingURL(baseURL: baseURL, contentUrl: contentUrl)
        return AuthenticatedStream(
            url: url,
            headers: ["Authorization": "Bearer \(token)"]
        )
    }

    // MARK: - Private Helpers

    private func normalizedBaseURLString(from base: String) throws -> String {
        try AudiobookshelfURLValidator.normalizedBaseURLString(from: base)
    }

    private func makeURL(base: String, path: String) throws -> URL {
        let normalised = try AudiobookshelfURLValidator.normalizedBaseURL(from: base)
        guard let url = URL(string: path, relativeTo: normalised)?.absoluteURL else {
            throw APIError.invalidURL
        }
        return url
    }

    private func authorizedRequest(url: URL, token: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
                throw APIError.serverUnreachable
            }
            throw APIError.networkError(urlError)
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AppLogger.network.error("Decoding \(String(describing: type)) failed: \(error.localizedDescription, privacy: .private)")
            throw APIError.decodingError(error)
        }
    }

    private func handleUnauthorized(for baseURL: String) async {
        do {
            try await AudiobookshelfAuth.shared.deleteToken(for: baseURL)
        } catch {
            AppLogger.network.error("Failed to delete expired token from Keychain: \(error.localizedDescription, privacy: .private)")
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .audiobookshelfTokenExpired, object: nil)
        }
    }
}
