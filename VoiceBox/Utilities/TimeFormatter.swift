import Foundation

struct TimeFormatter {
    static func playback(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func compact(_ seconds: Int) -> String {
        let sanitizedSeconds = max(0, seconds)
        let minutes = sanitizedSeconds / 60
        let secs = sanitizedSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    static func human(_ seconds: Int) -> String {
        let sanitizedSeconds = max(0, seconds)
        let hours = sanitizedSeconds / 3600
        let minutes = (sanitizedSeconds % 3600) / 60
        let secs = sanitizedSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }

        if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }

        return "\(secs)s"
    }
}
