import Foundation

/// Remembers, per book, when its playback position last really changed and
/// whether that change still has to reach the Audiobookshelf server.
///
/// Only audio actually playing or a user seek counts as a change. Loading a
/// book, the resume seek and re-saving an unchanged position don't, so the time
/// can be compared with the server's progress to decide which one is newer.
/// Stored in UserDefaults, keyed by book ID.
@MainActor
final class PlaybackProgressTracker {
    static let shared = PlaybackProgressTracker()

    nonisolated struct State: Equatable, Sendable {
        var changedAt: Date
        var isDirty: Bool
    }

    /// Continuous playback is persisted at most this often.
    private let persistInterval: TimeInterval = 5
    private let defaults: UserDefaults
    private var cache: [UUID: State] = [:]
    private var lastPersistedAt: [UUID: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordChange(bookID: UUID, at date: Date = Date()) {
        let previous = state(for: bookID)
        cache[bookID] = State(changedAt: date, isDirty: true)
        let persistedAt = lastPersistedAt[bookID] ?? .distantPast
        if previous?.isDirty != true || date.timeIntervalSince(persistedAt) >= persistInterval {
            persist(bookID)
        }
    }

    /// The server now has this book's latest position.
    func markSynced(bookID: UUID) {
        guard var current = state(for: bookID), current.isDirty else { return }
        current.isDirty = false
        cache[bookID] = current
        persist(bookID)
    }

    func state(for bookID: UUID) -> State? {
        if let cached = cache[bookID] { return cached }
        guard let stored = defaults.dictionary(forKey: key(for: bookID)),
              let changedAt = stored["changedAt"] as? Double,
              let isDirty = stored["dirty"] as? Bool else { return nil }
        let state = State(changedAt: Date(timeIntervalSince1970: changedAt), isDirty: isDirty)
        cache[bookID] = state
        return state
    }

    func lastChange(bookID: UUID) -> Date? { state(for: bookID)?.changedAt }

    func isDirty(bookID: UUID) -> Bool { state(for: bookID)?.isDirty ?? false }

    /// Writes any throttled change now, e.g. before the app is suspended.
    func flush() {
        for bookID in cache.keys { persist(bookID) }
    }

    func clear(bookID: UUID) {
        cache[bookID] = nil
        lastPersistedAt[bookID] = nil
        defaults.removeObject(forKey: key(for: bookID))
    }

    private func persist(_ bookID: UUID) {
        guard let state = cache[bookID] else { return }
        defaults.set(
            ["changedAt": state.changedAt.timeIntervalSince1970, "dirty": state.isDirty],
            forKey: key(for: bookID)
        )
        lastPersistedAt[bookID] = Date()
    }

    private func key(for bookID: UUID) -> String {
        "playbackProgressState_\(bookID.uuidString)"
    }
}
