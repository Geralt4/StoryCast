import Foundation

// MARK: - Import Phase

/// Represents the current phase of an import operation.
///
/// Import operations progress through these phases:
/// 1. `.idle` - No import in progress
/// 2. `.downloading` - Downloading file from cloud storage
/// 3. `.processing` - Processing and saving the imported file
enum ImportPhase: String {
    case idle = "Idle"
    case downloading = "Downloading"
    case processing = "Processing"
}

// MARK: - Import Error Types

/// Categorizes import errors for appropriate handling and user messaging.
///
/// Each error type indicates:
/// - Whether the error is transient (can be retried)
/// - A user-friendly error message
/// - The appropriate recovery action
enum ImportErrorType {
    /// No internet connection available
    case networkUnavailable
    
    /// Network request timed out
    case networkTimeout
    
    /// Connection lost during download
    case connectionLost
    
    /// User denied file access permissions
    case fileAccessDenied
    
    /// File not found at expected location
    case fileNotFound
    
    /// Audio format not supported by the app
    case unsupportedFormat
    
    /// File is DRM-protected
    case drmProtected
    
    /// Unknown or uncategorized error
    case unknown
    
    /// Whether this error is transient and can be retried automatically.
    ///
    /// - Returns: `true` for network-related errors that may succeed on retry
    var isTransient: Bool {
        switch self {
        case .networkTimeout, .connectionLost:
            return true
        default:
            return false
        }
    }
    
    /// User-friendly error message for display in the UI.
    ///
    /// Messages are actionable and explain what the user can do to resolve the issue.
    var userMessage: String {
        switch self {
        case .networkUnavailable:
            return "No internet connection. Check your network and try again."
        case .networkTimeout:
            return "Download timed out. The file may be too large or the connection too slow."
        case .connectionLost:
            return "Connection lost during download. Please try again."
        case .fileAccessDenied:
            return "Cannot access this file. You may need to re-authenticate with the cloud service."
        case .fileNotFound:
            return "File not found. It may have been moved or deleted."
        case .unsupportedFormat:
            return "This file format is not supported."
        case .drmProtected:
            return "This book is DRM-protected and cannot be imported. Try exporting it from your audiobook service first."
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}

// MARK: - Failed Import Record

/// Tracks a failed import operation for retry and display purposes.
///
/// `FailedImport` records contain:
/// - The original file URL
/// - Error details and classification
/// - Retry count for exponential backoff
struct FailedImport: Identifiable {
    /// Original file URL that failed to import
    let url: URL
    
    /// Display name of the file
    let fileName: String
    
    /// Classified error type
    let errorType: ImportErrorType
    
    /// Full error message for display
    let errorMessage: String
    
    /// Number of retry attempts made
    var retryCount: Int = 0
    
    /// Maximum retry attempts before giving up
    let maxRetries: Int = ImportDefaults.maxRetries
    
    /// Whether this import can be automatically retried.
    ///
    /// Auto-retry is allowed for transient errors when under the retry limit.
    var canAutoRetry: Bool {
        errorType.isTransient && retryCount < maxRetries
    }

    /// Stable identity for this failed import, derived from its source URL.
    var id: String { sourceKey }

    /// Canonical source key used for deduping failure records and retry tasks.
    var sourceKey: String { Self.normalizedSourceKey(for: url) }

    nonisolated static func normalizedSourceKey(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }
        return url.absoluteString
    }
}

// MARK: - Import Error (UI Display)

/// Simple error wrapper for UI display in the failed imports section.
///
/// Used to display import errors in the library view with proper identification.
struct ImportDisplayError: Identifiable {
    /// Unique identifier
    let id = UUID()
    
    /// Name of the file that failed to import
    let fileName: String
    
    /// The underlying error
    let error: Error
}
