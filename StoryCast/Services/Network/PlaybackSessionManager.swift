import Foundation
import Combine
import SwiftData
import os
#if canImport(UIKit)
import UIKit
#endif

/// Manages Audiobookshelf playback sessions for remote books.
///
/// Responsibilities:
/// - Opens a session via `POST /api/items/:id/play` and returns the streaming URL.
/// - Periodically syncs `currentTime` to the server every 30 seconds while the app
///   is in the foreground.
/// - While in the background, pauses the 30-second timer and uses a 5-minute interval
///   instead to respect iOS background execution limits.
/// - Closes the session (with a final sync) when playback stops or the book changes.
@MainActor
final class PlaybackSessionManager: ObservableObject {
    static let shared = PlaybackSessionManager()

    private let terminationWaitTimeout: TimeInterval = 5.0
    private let progressBackupEpsilon: TimeInterval = 1.0

    // MARK: - Published State

    @Published private(set) var activeSessionId: String?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncError: Error?

    var activeRemoteItemId: String? { currentItemId }
    var activeRemoteServerID: UUID? { currentServer?.id }

    // MARK: - Private

    private var syncTimer: Timer?
    private var backgroundSyncTimer: Timer?
    private var isInBackground: Bool = false
    private var currentServer: ABSServer?
    private var currentItemId: String?
    private var sessionStartTime: Double = 0
    private var lastSyncedTime: Double = 0
    private var sessionDuration: Double = 0
    private var totalTimeListened: Double = 0
    private var lastObservedTime: Double = 0
    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var lifecycleObservers: [Any] = []
    private var isTerminating = false
    private var isSeeking = false

    private init() {
        // Observe AudioPlayerService to track listening time accurately.
        AudioPlayerService.shared.$currentTime
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] newTime in
                guard let self else { return }
                // Only accumulate time when moving forward (not seeking backward)
                // and when actually playing (not paused at the end)
                let isPlaying = AudioPlayerService.shared.isPlaying
                let hasAdvanced = newTime > self.lastObservedTime
                
                if isPlaying && hasAdvanced && !self.isSeeking {
                    let increment = newTime - self.lastObservedTime
                    self.totalTimeListened += increment
                }
                if self.isSeeking {
                    self.isSeeking = false
                }
                self.lastObservedTime = newTime
            }
            .store(in: &cancellables)

        // Register for app lifecycle notifications to manage the sync timer.
        #if canImport(UIKit)
        let center = NotificationCenter.default
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleAppDidEnterBackground()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleAppWillEnterForeground()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleAppWillTerminate()
            }
        })
        #endif
        
        // Observe network transitions for auto-reconnect
        NetworkMonitor.shared.$isExpensive
            .removeDuplicates()
            .sink { [weak self] isExpensive in
                guard let self, self.activeSessionId != nil else { return }
                Task { @MainActor in
                    await self.handleNetworkTransition(toCellular: isExpensive)
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - App Lifecycle

    private func handleAppDidEnterBackground() {
        guard activeSessionId != nil else { return }
        isInBackground = true

        performBackgroundSyncTask(named: "StoryCast.ProgressSync") { [weak self] in
            guard let self else { return }
            await self.syncProgressForBackgroundTransition()
        }

        // Stop the 30-second foreground timer and start a 5-minute background timer.
        stopSyncTimer()
        startBackgroundSyncTimer()
        AppLogger.sync.debug("Entered background — switched to 5-minute sync interval")
    }

    private func handleAppWillEnterForeground() {
        guard activeSessionId != nil else { return }
        isInBackground = false

        // Stop the background timer, do an immediate sync, resume the normal timer.
        stopBackgroundSyncTimer()
        Task { await syncProgress() }
        startSyncTimer()
        AppLogger.sync.debug("Entered foreground — resumed 30-second sync interval")
    }

    func isCurrentSession(for book: Book) -> Bool {
        guard book.isRemote,
              let itemId = book.remoteItemId,
              let serverId = book.serverId else {
            return false
        }

        return currentItemId == itemId && currentServer?.id == serverId
    }
    
    private func handleNetworkTransition(toCellular isExpensive: Bool) async {
        guard activeSessionId != nil,
              let server = currentServer,
              let itemId = currentItemId else { return }
        
        guard AudioPlayerService.shared.isPlaying else {
            AppLogger.sync.debug("Network transitioned but player is paused — no reconnection needed")
            return
        }
        
        let wasPlaying = AudioPlayerService.shared.isPlaying
        let currentPosition = AudioPlayerService.shared.currentTime
        
        AppLogger.sync.info("Network transitioned to \(isExpensive ? "cellular" : "WiFi") — attempting reconnection")
        
        await closeCurrentSession()
        
        do {
            _ = try await reconnectSession(server: server, itemId: itemId, resumePosition: currentPosition)
            
            AudioPlayerService.shared.seek(to: currentPosition)
            
            if wasPlaying {
                AudioPlayerService.shared.play()
            }
            
            AppLogger.sync.info("Successfully reconnected after network transition")
        } catch {
            AppLogger.sync.error("Failed to reconnect after network transition: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    private func reconnectSession(server: ABSServer, itemId: String, resumePosition: Double) async throws -> AuthenticatedStream {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }
        
        AppLogger.sync.info("Reconnecting playback session for item \(itemId, privacy: .private)")
        
        let session = try await AudiobookshelfAPI.shared.startPlaybackSession(
            baseURL: server.normalizedURL,
            token: token,
            itemId: itemId
        )
        
        guard let firstTrack = session.audioTracks.first,
              let contentUrl = firstTrack.contentUrl else {
            throw APIError.invalidResponse
        }
        
        let stream = try await AudiobookshelfAPI.shared.authenticatedStream(
            baseURL: server.normalizedURL,
            token: token,
            contentUrl: contentUrl
        )
        
        activeSessionId = session.id
        currentServer = server
        currentItemId = itemId
        sessionDuration = session.duration ?? sessionDuration
        sessionStartTime = session.currentTime ?? resumePosition
        lastSyncedTime = sessionStartTime
        lastObservedTime = sessionStartTime
        totalTimeListened = 0
        
        startSyncTimer()
        
        AppLogger.sync.info("Session \(session.id, privacy: .private) reconnected")
        return stream
    }

    private func handleAppWillTerminate() {
        guard activeSessionId != nil, let sessionId = activeSessionId else { return }
        guard let server = currentServer, let itemId = currentItemId else { return }
        
        isTerminating = true
        
        stopSyncTimer()
        stopBackgroundSyncTimer()
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        
        #if canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StoryCast.SessionSync")
        guard backgroundTaskID != .invalid else {
            Task {
                await handleTerminationSync(sessionId: sessionId, server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
            }
            return
        }
        
        let taskID = backgroundTaskID
        Task {
            await handleTerminationSync(sessionId: sessionId, server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
            UIApplication.shared.endBackgroundTask(taskID)
        }
        #else
        Task {
            await handleTerminationSync(sessionId: sessionId, server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
        }
        #endif
    }
    
    private func handleTerminationSync(sessionId: String, server: ABSServer, itemId: String, currentTime: Double, listened: Double, duration: Double) async {
        if let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) {
            do {
                try await AudiobookshelfAPI.shared.closeSession(
                    baseURL: server.normalizedURL,
                    token: token,
                    sessionId: sessionId,
                    currentTime: currentTime,
                    timeListened: listened,
                    duration: duration
                )
                clearPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId)
                AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at termination")
            } catch {
                AppLogger.sync.error("Failed to close session at termination: \(error.localizedDescription, privacy: .private)")
                backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            }
        } else {
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
        }
        
        clearSession()
    }
    
    private func backupProgressLocally(serverURL: String, itemId: String, currentTime: Double, timeListened: Double, duration: Double) {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        let backup: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
            "timestamp": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(backup, forKey: key)
        AppLogger.sync.warning("Progress backed up locally due to sync failure: \(currentTime)s")
    }
    
    func attemptPendingProgressRecovery(server: ABSServer, itemId: String) async {
        let key = pendingProgressKey(serverURL: server.normalizedURL, itemId: itemId)
        guard let backup = UserDefaults.standard.dictionary(forKey: key),
              let currentTime = backup["currentTime"] as? Double,
              let _ = backup["timeListened"] as? Double,
              let duration = backup["duration"] as? Double else {
            return
        }
        
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            return
        }
        
        do {
            try await AudiobookshelfAPI.shared.updateProgress(
                baseURL: server.normalizedURL,
                token: token,
                itemId: itemId,
                currentTime: currentTime,
                duration: duration,
                isFinished: duration > 0 && currentTime >= duration - 10
            )
            clearPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.info("Recovered pending progress: \(currentTime)s")
        } catch {
            AppLogger.sync.error("Failed to recover pending progress: \(error.localizedDescription, privacy: .private)")
        }
    }

    func recoverPendingProgressIfNeeded(container: ModelContainer) async {
        let context = ModelContext(container)

        do {
            let books = try context.fetch(FetchDescriptor<Book>())
            let servers = try context.fetch(FetchDescriptor<ABSServer>())
            let serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })

            for book in books where book.isRemote {
                guard let itemId = book.remoteItemId,
                      let serverID = book.serverId,
                      let server = serversByID[serverID],
                      hasPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId) else {
                    continue
                }

                await attemptPendingProgressRecovery(server: server, itemId: itemId)
            }
        } catch {
            AppLogger.sync.error("Failed to recover pending progress at startup: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Session Lifecycle

    /// Opens a playback session for the given book on the given server.
    /// Returns the first audio track's authenticated stream to pass to `AudioPlayerService`.
    func startSession(for book: Book, server: ABSServer) async throws -> AuthenticatedStream {
        guard let itemId = book.remoteItemId else {
            throw APIError.noActiveSession
        }
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }

        // Close any existing session first.
        await closeCurrentSession()
        await attemptPendingProgressRecovery(server: server, itemId: itemId)

        AppLogger.sync.info("Starting playback session for item \(itemId, privacy: .private)")

        let session = try await AudiobookshelfAPI.shared.startPlaybackSession(
            baseURL: server.normalizedURL,
            token: token,
            itemId: itemId
        )

        guard let firstTrack = session.audioTracks.first,
              let contentUrl = firstTrack.contentUrl else {
            throw APIError.invalidResponse
        }

        let stream = try await AudiobookshelfAPI.shared.authenticatedStream(
            baseURL: server.normalizedURL,
            token: token,
            contentUrl: contentUrl
        )

        activeSessionId = session.id
        currentServer = server
        currentItemId = itemId
        sessionDuration = session.duration ?? book.duration
        sessionStartTime = session.currentTime ?? book.lastPlaybackPosition
        lastSyncedTime = sessionStartTime
        lastObservedTime = sessionStartTime
        totalTimeListened = 0

        // Start the appropriate timer based on current app state.
        #if canImport(UIKit)
        let isCurrentlyInBackground = UIApplication.shared.applicationState == .background
        #else
        let isCurrentlyInBackground = isInBackground
        #endif
        
        if isCurrentlyInBackground {
            isInBackground = true
            startBackgroundSyncTimer()
        } else {
            isInBackground = false
            startSyncTimer()
        }

        AppLogger.sync.info("Session \(session.id, privacy: .private) started; streaming from \(stream.url.host ?? "unknown", privacy: .private)")
        return stream
    }

    /// Closes the current session with a final progress sync.
    func closeCurrentSession() async {
        stopSyncTimer()
        stopBackgroundSyncTimer()

        guard let sessionId = activeSessionId,
              let server = currentServer,
              let itemId = currentItemId else { return }

        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration

        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            clearSession()
            return
        }

        do {
            try await AudiobookshelfAPI.shared.closeSession(
                baseURL: server.normalizedURL,
                token: token,
                sessionId: sessionId,
                currentTime: currentTime,
                timeListened: listened,
                duration: duration
            )
            clearPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at \(currentTime)s (total listened: \(listened)s)")
        } catch {
            AppLogger.sync.error("Failed to close session: \(error.localizedDescription, privacy: .private)")
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
        }

        clearSession()
    }

    // MARK: - Sync Timers

    private func startSyncTimer() {
        stopSyncTimer()
        syncTimer = Timer.scheduledTimer(
            withTimeInterval: AudiobookshelfDefaults.progressSyncInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionId != nil, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func startBackgroundSyncTimer() {
        stopBackgroundSyncTimer()
        backgroundSyncTimer = Timer.scheduledTimer(
            withTimeInterval: AudiobookshelfDefaults.backgroundProgressSyncInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionId != nil, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }

    private func stopBackgroundSyncTimer() {
        backgroundSyncTimer?.invalidate()
        backgroundSyncTimer = nil
    }

    // MARK: - Progress Sync

    func syncProgress() async {
        // Early exit if already syncing to prevent double-sync
        guard !isSyncing else { return }
        
        guard let sessionId = activeSessionId,
              let server = currentServer else { return }

        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else { return }

        let currentTime = AudioPlayerService.shared.currentTime

        guard totalTimeListened >= AudiobookshelfDefaults.minTimeListenedToSync else { return }

        lastSyncError = nil
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await AudiobookshelfAPI.shared.syncSession(
                baseURL: server.normalizedURL,
                token: token,
                sessionId: sessionId,
                currentTime: currentTime,
                timeListened: self.totalTimeListened,
                duration: sessionDuration
            )
            let listenedBeforeClear = self.totalTimeListened
            lastSyncedTime = currentTime
            lastSyncError = nil
            totalTimeListened = 0
            if let itemId = currentItemId {
                clearPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId)
            }
            AppLogger.sync.debug("Synced progress: \(currentTime)s (listened \(listenedBeforeClear)s)")
        } catch {
            lastSyncError = error
            AppLogger.sync.error("Progress sync failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func syncProgressForBackgroundTransition() async {
        guard !isSyncing,
              let sessionId = activeSessionId,
              let server = currentServer,
              let itemId = currentItemId else {
            return
        }

        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        let hasUnsyncedProgress = listened > 0 || abs(currentTime - lastSyncedTime) >= progressBackupEpsilon

        guard hasUnsyncedProgress else { return }

        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            return
        }

        guard listened >= AudiobookshelfDefaults.minTimeListenedToSync else {
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            AppLogger.sync.debug("Backed up pending progress while entering background: \(currentTime)s")
            return
        }

        lastSyncError = nil
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await AudiobookshelfAPI.shared.syncSession(
                baseURL: server.normalizedURL,
                token: token,
                sessionId: sessionId,
                currentTime: currentTime,
                timeListened: listened,
                duration: duration
            )
            lastSyncedTime = currentTime
            lastSyncError = nil
            totalTimeListened = 0
            clearPendingProgressBackup(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.debug("Synced progress while entering background: \(currentTime)s (listened \(listened)s)")
        } catch {
            lastSyncError = error
            backupProgressLocally(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            AppLogger.sync.error("Background progress sync failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Private Helpers

    private func performBackgroundSyncTask(
        named taskName: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        #if canImport(UIKit)
        let taskID = UIApplication.shared.beginBackgroundTask(withName: taskName, expirationHandler: nil)
        guard taskID != .invalid else {
            Task { @MainActor in
                await operation()
            }
            return
        }

        Task { @MainActor in
            await operation()
            UIApplication.shared.endBackgroundTask(taskID)
        }
        #else
        Task { @MainActor in
            await operation()
        }
        #endif
    }

    private func clearSession() {
        activeSessionId = nil
        currentServer = nil
        currentItemId = nil
        sessionDuration = 0
        sessionStartTime = 0
        lastSyncedTime = 0
        totalTimeListened = 0
        lastObservedTime = 0
        isInBackground = false
    }

    private func pendingProgressKey(serverURL: String, itemId: String) -> String {
        let normalizedServer: String
        do {
            normalizedServer = try AudiobookshelfURLValidator.normalizedBaseURLString(from: serverURL)
        } catch {
            AppLogger.network.debug("Could not normalize server URL for progress key: \(error.localizedDescription, privacy: .private)")
            normalizedServer = serverURL
        }
        let digest = Data(normalizedServer.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "pendingProgress_\(digest)_\(itemId)"
    }

    private func hasPendingProgressBackup(serverURL: String, itemId: String) -> Bool {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        return UserDefaults.standard.dictionary(forKey: key) != nil
    }

    private func clearPendingProgressBackup(serverURL: String, itemId: String) {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

#if DEBUG
extension PlaybackSessionManager {
    func debugPendingProgressKey(serverURL: String, itemId: String) -> String {
        pendingProgressKey(serverURL: serverURL, itemId: itemId)
    }

    func debugHasPendingProgress(serverURL: String, itemId: String) -> Bool {
        hasPendingProgressBackup(serverURL: serverURL, itemId: itemId)
    }

    func debugBackupProgress(serverURL: String, itemId: String, currentTime: Double, timeListened: Double, duration: Double) {
        backupProgressLocally(serverURL: serverURL, itemId: itemId, currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    func debugClearPendingProgress(serverURL: String, itemId: String) {
        clearPendingProgressBackup(serverURL: serverURL, itemId: itemId)
    }
}
#endif
