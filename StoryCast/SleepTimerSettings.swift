import Foundation
import os

/// User preferences for sleep timer behavior
struct SleepTimerSettings: Codable {
    var defaultDurationMinutes: Int = SleepTimerDefaults.defaultDurationMinutes
    
    // UserDefaults key
    static let userDefaultsKey = "SleepTimerSettings"
    
    /// Load saved settings or return defaults
    static func load() -> SleepTimerSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(SleepTimerSettings.self, from: data) else {
            return SleepTimerSettings()
        }
        return settings.sanitized()
    }
    
    /// Clamp values to valid ranges so corrupt/out-of-range UserDefaults data doesn't cause issues
    func sanitized() -> SleepTimerSettings {
        var copy = self
        if !SleepTimerDefaults.availableDurations.contains(copy.defaultDurationMinutes) {
            copy.defaultDurationMinutes = SleepTimerDefaults.defaultDurationMinutes
        }
        return copy
    }
    
    /// Save current settings to UserDefaults
    func save() {
        do {
            let data = try JSONEncoder().encode(sanitized())
            UserDefaults.standard.set(data, forKey: SleepTimerSettings.userDefaultsKey)
        } catch {
            AppLogger.settings.error("Failed to save SleepTimerSettings: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    /// Reset to factory defaults
    static func resetToDefaults() {
        let defaults = SleepTimerSettings()
        defaults.save()
    }
}

/// Default values for sleep timer settings
enum SleepTimerDefaults {
    static let defaultDurationMinutes: Int = 30
    static let availableDurations: [Int] = [15, 30, 45, 60]
    static let extensionOptions: [Int] = [5, 10, 15]
}
