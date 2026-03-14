import Foundation

/// Typed errors for all Audiobookshelf network operations.
enum APIError: LocalizedError {
    case unauthorized
    case serverUnreachable
    case serverNotInitialized
    case invalidURL
    case insecureConnection
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case networkError(Error)
    case noActiveServer
    case noActiveSession
    case tokenMissing
    case insufficientStorage(available: Int64, required: Int64)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid credentials. Please check your username and password."
        case .serverUnreachable:
            return "Cannot reach the server. Check the URL and your network connection."
        case .serverNotInitialized:
            return "The server is not yet set up. Please complete Audiobookshelf setup first."
        case .invalidURL:
            return "The server URL is invalid."
        case .insecureConnection:
            return "Only HTTPS Audiobookshelf servers are supported."
        case .invalidResponse:
            return "Received an unexpected response from the server."
        case .httpError(let code):
            return "Server returned an error (HTTP \(code))."
        case .decodingError(let error):
            return "Failed to parse server response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noActiveServer:
            return "No Audiobookshelf server is configured."
        case .noActiveSession:
            return "No active playback session."
        case .tokenMissing:
            return "Authentication token is missing. Please log in again."
        case .insufficientStorage(let available, let required):
            return "Not enough storage space. Available: \(available)MB, Required: \(required)MB"
        }
    }

    /// Whether the error is transient and worth retrying automatically.
    var isTransient: Bool {
        switch self {
        case .serverUnreachable, .networkError:
            return true
        case .insufficientStorage:
            return false
        default:
            return false
        }
    }
}
