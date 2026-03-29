import Foundation
import SwiftData
import os

/// Errors that can occur during storage version validation
enum StorageVersionError: Error, LocalizedError {
    case versionMismatchDetected(details: String)
    case migrationFailed(underlying: Error)
    case unknownError(underlying: Error)
    
    var errorDescription: String? {
        switch self {
        case .versionMismatchDetected:
            return "Database version mismatch detected"
        case .migrationFailed(let error):
            return "Migration failed: \(error.localizedDescription)"
        case .unknownError(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}

/// Validates storage version compatibility and detects mismatches
nonisolated enum StorageVersionValidator {
    
    // MARK: - Error Pattern Matching
    
    /// Keywords in error messages that indicate version mismatch
    private static var versionMismatchKeywords: [String] {
        [
            "checksum",
            "schema",
            "version",
            "NSStagedMigrationManager",
            "findCurrentMigrationStage",
            "identical models",
            "Unable to find source model",
            "model version",
            "model mismatch",
            "incompatible version",
            "store version",
            "metadata mismatch"
        ]
    }
    
    /// Checks if an error indicates a schema version mismatch
    nonisolated static func isVersionMismatchError(_ error: Error) -> Bool {
        let errorString = String(describing: error).lowercased()
        let localizedDescription = error.localizedDescription.lowercased()
        
        // Check both the error description and its string representation
        let combinedString = errorString + " " + localizedDescription
        
        return versionMismatchKeywords.contains { keyword in
            combinedString.contains(keyword.lowercased())
        }
    }
    
    /// Categorizes an error into a StorageVersionError
    nonisolated static func categorize(_ error: Error) -> StorageVersionError {
        if isVersionMismatchError(error) {
            return .versionMismatchDetected(details: error.localizedDescription)
        }
        
        // Check if it's a migration-related error
        let errorString = String(describing: error).lowercased()
        if errorString.contains("migration") {
            return .migrationFailed(underlying: error)
        }
        
        return .unknownError(underlying: error)
    }
    
    // MARK: - Analytics Logging
    
    /// Logs a version mismatch event for analytics
    /// - Parameters:
    ///   - error: The categorized error
    ///   - schemaVersion: The current app schema version string
    nonisolated static func logVersionMismatchEvent(
        error: StorageVersionError,
        schemaVersion: String
    ) {
        let parameters: [String: Any] = [
            "error_type": String(describing: type(of: error)),
            "current_schema_version": schemaVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "error_description": error.localizedDescription
        ]
        
        // Log to AppLogger for debugging (nonisolated unsafe access)
        // This is a workaround since AppLogger is MainActor isolated
        Task { @MainActor in
            AppLogger.app.warning("Storage version mismatch detected: \(parameters)")
        }
        
        // TODO: Send to analytics service (Firebase, etc.)
        // Analytics.logEvent("storage_version_mismatch", parameters: parameters)
    }
    
    // MARK: - User Messages
    
    /// Returns a user-friendly message for the error
    nonisolated static func userMessage(for error: StorageVersionError) -> String {
        switch error {
        case .versionMismatchDetected:
            return "Your library was created with a newer version of StoryCast. You can try to recover your data or start fresh."
        case .migrationFailed:
            return "There was a problem updating your library. You can try to recover your data or start fresh."
        case .unknownError:
            return "There was a problem opening your library. You can try to recover your data or start fresh."
        }
    }
    
    /// Returns technical details for error reporting
    nonisolated static func technicalDetails(for error: StorageVersionError) -> String {
        switch error {
        case .versionMismatchDetected(let details):
            return "Version mismatch: \(details)"
        case .migrationFailed(let underlying):
            return "Migration failed: \(underlying.localizedDescription)"
        case .unknownError(let underlying):
            return "Unknown error: \(underlying.localizedDescription)"
        }
    }
}