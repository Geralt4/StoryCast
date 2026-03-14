import Foundation

enum ImportServiceError: LocalizedError {
    case unsupportedFormat(String)
    case downloadTimedOut
    case invalidDuration
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let message):
            return message
        case .downloadTimedOut:
            return "Download timed out"
        case .invalidDuration:
            return "Could not determine audio duration"
        }
    }
}