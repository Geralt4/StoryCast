import Foundation

/// Default constants for Audiobookshelf integration.
enum AudiobookshelfDefaults {
    /// Number of items to fetch per page when loading library items.
    static let pageSize = 50
    
    /// Default cover art size in pixels.
    static let coverArtSize = 400
    
    /// Interval in seconds for syncing playback progress to the server (30 seconds).
    static let progressSyncInterval: TimeInterval = 30.0
    
    /// Interval in seconds for syncing playback progress when in background (5 minutes).
    static let backgroundProgressSyncInterval: TimeInterval = 300.0
    
    /// Minimum time listened in seconds before syncing progress (10 seconds).
    static let minTimeListenedToSync: TimeInterval = 10.0
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the Audiobookshelf token expires and needs re-authentication.
    nonisolated static let audiobookshelfTokenExpired = Notification.Name("audiobookshelfTokenExpired")
}
