import Foundation

enum AudiobookshelfURLValidator {
    nonisolated static func normalizedBaseURLString(from rawValue: String) throws -> String {
        try normalizedBaseURL(from: rawValue).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func normalizedBaseURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.invalidURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            throw APIError.invalidURL
        }

        guard let scheme = components.scheme?.lowercased() else {
            throw APIError.invalidURL
        }
        guard scheme == "https" else {
            throw APIError.insecureConnection
        }
        guard components.user == nil, components.password == nil else {
            throw APIError.invalidURL
        }
        guard let host = components.host, !host.isEmpty else {
            throw APIError.invalidURL
        }
        guard components.query == nil, components.fragment == nil else {
            throw APIError.invalidURL
        }
        guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw APIError.invalidURL
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.percentEncodedPath = ""

        guard let url = components.url else {
            throw APIError.invalidURL
        }
        return url
    }

    nonisolated static func validatedStreamingURL(baseURL rawBaseURL: String, contentURL rawContentURL: String) throws -> URL {
        let baseURL = try normalizedBaseURL(from: rawBaseURL)
        let trimmedContentURL = rawContentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContentURL.isEmpty, !trimmedContentURL.hasPrefix("//") else {
            throw APIError.invalidURL
        }

        if let absoluteURL = URL(string: trimmedContentURL), absoluteURL.scheme != nil {
            return try validateAbsoluteStreamingURL(absoluteURL, against: baseURL)
        }

        return try buildRelativeStreamingURL(trimmedContentURL, against: baseURL)
    }

    nonisolated private static func validateAbsoluteStreamingURL(_ url: URL, against baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        guard components.user == nil, components.password == nil, components.fragment == nil else {
            throw APIError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw APIError.insecureConnection
        }
        guard sameOrigin(url, baseURL) else {
            throw APIError.invalidURL
        }
        guard isSafePath(components.percentEncodedPath), !hasSensitiveQueryItem(components.queryItems) else {
            throw APIError.invalidURL
        }

        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil

        guard let validatedURL = components.url else {
            throw APIError.invalidURL
        }
        return validatedURL
    }

    nonisolated private static func buildRelativeStreamingURL(_ contentURL: String, against baseURL: URL) throws -> URL {
        let normalizedPath = contentURL.hasPrefix("/") ? contentURL : "/\(contentURL)"
        guard let relativeComponents = URLComponents(string: normalizedPath) else {
            throw APIError.invalidURL
        }
        guard relativeComponents.scheme == nil,
              relativeComponents.host == nil,
              relativeComponents.user == nil,
              relativeComponents.password == nil,
              relativeComponents.fragment == nil,
              isSafePath(relativeComponents.percentEncodedPath),
              !hasSensitiveQueryItem(relativeComponents.queryItems) else {
            throw APIError.invalidURL
        }

        guard var absoluteComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        absoluteComponents.percentEncodedPath = relativeComponents.percentEncodedPath
        absoluteComponents.queryItems = relativeComponents.queryItems
        absoluteComponents.fragment = nil

        guard let validatedURL = absoluteComponents.url else {
            throw APIError.invalidURL
        }
        return validatedURL
    }

    nonisolated private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
        lhs.host?.lowercased() == rhs.host?.lowercased() &&
        effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    nonisolated private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    nonisolated private static func isSafePath(_ percentEncodedPath: String) -> Bool {
        let path = (percentEncodedPath.removingPercentEncoding ?? percentEncodedPath)
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains(where: { $0 == "." || $0 == ".." })
    }

    nonisolated private static func hasSensitiveQueryItem(_ queryItems: [URLQueryItem]?) -> Bool {
        guard let queryItems else { return false }
        return queryItems.contains { $0.name.caseInsensitiveCompare("token") == .orderedSame }
    }
}
