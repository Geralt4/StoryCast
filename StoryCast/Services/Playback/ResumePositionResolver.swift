import Foundation

/// A book's progress as stored on the Audiobookshelf server.
nonisolated struct ServerProgressSnapshot: Sendable, Equatable {
    let currentTime: Double
    let duration: Double?
    let isFinished: Bool
    /// When the server last updated this progress, by the server's clock.
    let lastUpdate: Date?
    /// Server clock minus device clock, from the response's `Date` header.
    let serverClockOffset: TimeInterval?

    /// `lastUpdate` on this device's clock, when it can be corrected.
    var lastUpdateOnDeviceClock: Date? {
        guard let lastUpdate else { return nil }
        return lastUpdate.addingTimeInterval(-(serverClockOffset ?? 0))
    }
}

/// Chooses where to resume a remote book: this device's position or the
/// server's, whichever is newer, so an older position here is never pushed
/// over progress made on another device.
nonisolated enum ResumePositionResolver {
    nonisolated struct Local: Sendable, Equatable {
        var position: Double
        /// When the position last really changed on this device.
        var changedAt: Date?
        /// The change hasn't reached the server yet.
        var isDirty: Bool
    }

    nonisolated struct Decision: Sendable, Equatable {
        enum Source: Sendable, Equatable { case local, server }
        var position: Double
        var source: Source
    }

    /// How far apart the two clocks' timestamps must be to call one newer:
    /// small when the server's clock offset is known, wide when it isn't.
    static let knownOffsetTolerance: TimeInterval = 10
    static let unknownOffsetTolerance: TimeInterval = 300

    static func resolve(local: Local, server: ServerProgressSnapshot?, timelineDuration: Double) -> Decision {
        func clamp(_ position: Double) -> Double {
            guard position.isFinite, position > 0 else { return 0 }
            return timelineDuration > 0 ? min(position, timelineDuration) : position
        }
        let localDecision = Decision(position: clamp(local.position), source: .local)
        guard let server else { return localDecision }
        let serverDecision = Decision(position: server.isFinished ? 0 : clamp(server.currentTime), source: .server)

        // Nothing here that the server hasn't seen: the server is up to date.
        guard local.isDirty, let changedAt = local.changedAt else { return serverDecision }
        // Unsynced changes here and no server timestamp to compare: keep ours.
        guard let serverTime = server.lastUpdateOnDeviceClock else { return localDecision }

        let tolerance = server.serverClockOffset == nil ? unknownOffsetTolerance : knownOffsetTolerance
        if serverTime > changedAt.addingTimeInterval(tolerance) {
            return serverDecision
        }
        // Ours is newer, or too close to call while it hasn't been synced.
        return localDecision
    }

    /// Parses an HTTP `Date` header (RFC 1123).
    static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
