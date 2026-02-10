import Foundation
import os

/// Playback-related user preferences
struct PlaybackSettings: Codable {
    // UserDefaults key (consistent with other settings files)
    static let userDefaultsKey = "PlaybackSettings"
    
    // Skip intervals
    var skipForwardSeconds: Double = PlaybackDefaults.skipForwardSeconds
    var skipBackwardSeconds: Double = PlaybackDefaults.skipBackwardSeconds
    
    // Playback speed
    var defaultPlaybackSpeed: Float = PlaybackDefaults.defaultPlaybackSpeed
    
    // Auto-play behavior
    var autoPlayNextChapter: Bool = PlaybackDefaults.autoPlayNextChapter
    
    // Static load/save methods for persistence
    static func load() -> PlaybackSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return PlaybackSettings()
        }
        return settings.sanitized()
    }

    func save() {
        let settings = sanitized()
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: PlaybackSettings.userDefaultsKey)
        } catch {
            AppLogger.settings.error("Failed to save PlaybackSettings: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    static func resetToDefaults() {
        let defaults = PlaybackSettings()
        defaults.save()
    }

    private func sanitized() -> PlaybackSettings {
        var sanitized = self
        sanitized.skipForwardSeconds = min(max(sanitized.skipForwardSeconds, PlaybackRanges.skipSeconds.lowerBound), PlaybackRanges.skipSeconds.upperBound)
        sanitized.skipBackwardSeconds = min(max(sanitized.skipBackwardSeconds, PlaybackRanges.skipSeconds.lowerBound), PlaybackRanges.skipSeconds.upperBound)
        sanitized.defaultPlaybackSpeed = min(max(sanitized.defaultPlaybackSpeed, PlaybackRanges.playbackSpeed.lowerBound), PlaybackRanges.playbackSpeed.upperBound)
        return sanitized
    }
}
