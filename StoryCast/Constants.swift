import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#endif

/// Default values for playback settings
enum PlaybackDefaults {
    /// Skip forward interval (seconds)
    static let skipForwardSeconds: Double = 30.0
    
    /// Skip backward interval (seconds)
    static let skipBackwardSeconds: Double = 15.0
    
    /// Default playback speed (1.0 = normal)
    static let defaultPlaybackSpeed: Float = 1.0

    /// Playback speed options for picker
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    
    /// Auto-play next chapter when current ends
    static let autoPlayNextChapter: Bool = true

    /// Supported skip symbols for system icons
    static let supportedSkipSymbolIntervals: [Int] = [5, 10, 15, 30, 45, 60, 75, 90]

    /// Time observer interval for audio player updates
    static let timeObserverInterval: TimeInterval = 1.0
}

/// Valid ranges for playback settings UI
enum PlaybackRanges {
    /// Skip intervals in seconds
    static let skipSeconds: ClosedRange<Double> = 5.0...60.0
    
    /// Playback speed multiplier (0.5x to 3.0x)
    static let playbackSpeed: ClosedRange<Float> = 0.5...3.0
}

enum TimerDefaults {
    static let tickInterval: TimeInterval = 1.0
    static let progressPollingNanoseconds: UInt64 = 500_000_000
}

enum ImportDefaults {
    static let downloadTimeout: TimeInterval = 300
    static let maxRetries: Int = 3
}

enum AnimationDefaults {
    static let shortDuration: Double = 0.2
    static let errorToastNanoseconds: UInt64 = 2_000_000_000
}

enum PerformanceDefaults {
    /// Debounce interval for search text updates (nanoseconds)
    static let searchDebounceNanoseconds: UInt64 = 150_000_000  // 150ms
    
    /// Debounce interval for playback position saves (nanoseconds)
    static let playbackSaveDebounceNanoseconds: UInt64 = 2_000_000_000  // 2 seconds
    
    /// Periodic save interval during playback (seconds)
    static let periodicPlaybackSaveInterval: TimeInterval = 60.0
}

enum LayoutDefaults {
    static let horizontalPadding: CGFloat = 24
    static let contentPadding: CGFloat = 20
    static let mediumSpacing: CGFloat = 12
    static let smallSpacing: CGFloat = 8
    static let tinySpacing: CGFloat = 2
    static let largeSpacing: CGFloat = 32
    static let extraLargeSpacing: CGFloat = 40
    static let sectionSpacing: CGFloat = 16
    static let badgeVerticalPadding: CGFloat = 6
    static let tooltipOffset: CGFloat = 50
    static let controlLabelSpacing: CGFloat = 4
    static let buttonRowSpacing: CGFloat = 10

    static let largeCornerRadius: CGFloat = 20
    static let sectionCornerRadius: CGFloat = 16
    static let overlayCornerRadius: CGFloat = 15
    static let badgeCornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 10

    static let playButtonSize: CGFloat = 72
    static let maxArtworkSize: CGFloat = 260
    static let artworkHorizontalInset: CGFloat = 80
    static let secondaryControlWidth: CGFloat = 60
    static let bookIconSize: CGFloat = 80
    static let mediumIconSize: CGFloat = 40
    static let largeIconSize: CGFloat = 48
    static let progressBarWidth: CGFloat = 150
    static let overlayPadding: CGFloat = 30
    static let overlayHorizontalPadding: CGFloat = 40
    static let overlayShadowRadius: CGFloat = 10

    static let smallSheetHeight: CGFloat = 200
    static let confirmationSheetHeight: CGFloat = 350

    static let playerTopPadding: CGFloat = 60

    static let shadowRadius: CGFloat = 20
    static let shadowYOffset: CGFloat = 10
}

enum ColorDefaults {
    static let subtleOpacity: Double = 0.1
    static let gradientStartOpacity: Double = 0.3
    static let gradientEndOpacity: Double = 0.1
    static let badgeOpacity: Double = 0.2
    static let overlayOpacity: Double = 0.4
    static let iconOpacity: Double = 0.6
    static let mutedTextOpacity: Double = 0.7
    static let errorOpacity: Double = 0.85
    static let nearSolidOpacity: Double = 0.9
}

enum MathDefaults {
    static let floatEpsilon: Float = 0.01
    static let minDurationSafetyValue: Double = 0.01
}

enum StorageDefaults {
    nonisolated static let coverArtCompressionQuality: CGFloat = 0.9
    nonisolated static let fileProtectionMigrationKey = "fileProtectionMigrationComplete"
    nonisolated static let remoteAssetMigrationKey = "remoteAssetMigrationComplete"
}

enum AccessibilityNotifications {
    static func announce(_ message: String) {
#if os(iOS)
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
#endif
    }
}

enum AppConstants {
    static let appName = "StoryCast"
    static let supportEmail = "johnmanologlou@gmail.com"
    static let privacyPolicyURL = "https://geralt4.github.io/StoryCast/privacy.html"
    static let supportURL = "https://geralt4.github.io/StoryCast/support.html"
}
