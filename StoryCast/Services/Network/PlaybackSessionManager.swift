import Foundation
import Combine
import SwiftData
import os
#if canImport(UIKit)
import UIKit
#endif

/// What the player needs to start streaming a remote book.
struct RemotePlaybackStart {
    let source: PlaybackSource
    let chapters: [ABSChapter]
    let resumePosition: Double
    let sessionDuration: Double
}

@MainActor
final class PlaybackSessionManager: ObservableObject {
    static let shared = PlaybackSessionManager()
    
    private let progressBackupEpsilon: TimeInterval = 1.0
    
    @Published private(set) var activeSessionId: String?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncError: Error?
    
    var activeRemoteItemId: String? { currentItemId }
    var activeRemoteServerID: UUID? { currentServer?.id }
    
    private var syncTimer: Timer?
    private var backgroundSyncTimer: Timer?
    private var isInBackground = false
    private var currentServer: ABSServer?
    private var currentItemId: String?
    private var activeTitle: String?
    private var activeBookID: UUID?
    private var apiOverride: AudiobookshelfAPI?
    private var api: AudiobookshelfAPI { apiOverride ?? .shared }
    private var sessionStartTime: Double = 0
    private var lastSyncedTime: Double = 0
    private var sessionDuration: Double = 0
    private var totalTimeListened: Double = 0
    private var lastObservedTime: Double = 0
    /// Wall-clock time of the previous playback tick while audio was advancing.
    private var lastListeningTick: Date?
    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var lifecycleObservers: [Any] = []
    private var isTerminating = false
    private(set) var isSeeking = false
    private var isSeekingClearTask: Task<Void, Never>?
    #if canImport(UIKit)
    private var activeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    private init() {
        let player = AudioPlayerService.shared
        player.$currentTime
            .sink { [weak self] newTime in
                self?.handlePlaybackTick(
                    newTime,
                    at: Date(),
                    isAudioAdvancing: player.isAudioAdvancing,
                    isSeekPending: player.isSeekPending,
                    bookID: player.currentBookID
                )
            }
            .store(in: &cancellables)
        player.$isAudioAdvancing
            .removeDuplicates()
            .sink { [weak self] isAdvancing in
                self?.lastListeningTick = isAdvancing ? Date() : nil
            }
            .store(in: &cancellables)
        // A load moves the position without anyone listening.
        player.$loadGeneration
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.lastListeningTick = nil
            }
            .store(in: &cancellables)
        
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppDidEnterBackground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppWillEnterForeground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Must start the background task before this handler returns or
            // the process can be killed before the deferred Task ever runs.
            MainActor.assumeIsolated { self?.handleAppWillTerminate() }
        })
        #endif
        
        NetworkMonitor.shared.$isExpensive.removeDuplicates()
            .sink { [weak self] isExpensive in
                guard let self, self.activeSessionId != nil else { return }
                Task { @MainActor in await self.handleNetworkTransition(toCellular: isExpensive) }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    func markSeeking() {
        isSeeking = true
        isSeekingClearTask?.cancel()
        isSeekingClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard !Task.isCancelled else { return }
            if self.isSeeking {
                self.isSeeking = false
                AppLogger.sync.warning("Cleared stuck isSeeking flag after timeout")
            }
        }
    }

    /// Counts listening time by the wall clock while audio is actually playing.
    /// The player publishes the time every second of *media* time, so at 1.5×
    /// ticks arrive every 0.67 s; summing wall-clock gaps (capped at 2 s, so a
    /// stall or suspension is not credited) gives the real time listened.
    func handlePlaybackTick(_ newTime: Double, at now: Date, isAudioAdvancing: Bool, isSeekPending: Bool, bookID: UUID?) {
        if isAudioAdvancing, !isSeekPending {
            if let lastTick = lastListeningTick, activeSessionId != nil {
                totalTimeListened += min(max(0, now.timeIntervalSince(lastTick)), 2)
            }
            lastListeningTick = now
            if let bookID {
                PlaybackProgressTracker.shared.recordChange(bookID: bookID, at: now)
            }
        }
        if isSeeking, !isSeekPending {
            isSeeking = false
        }
        lastObservedTime = newTime
    }

    func isCurrentSession(for book: Book) -> Bool {
        guard book.isRemote, let itemId = book.remoteItemId, let serverId = book.serverId else { return false }
        return currentItemId == itemId && currentServer?.id == serverId
    }
    
    func startSession(for book: Book, server: ABSServer) async throws -> RemotePlaybackStart {
        guard let itemId = book.remoteItemId else { throw APIError.noActiveSession }
        let bookID = book.id
        let title = book.title
        let resumePosition = book.lastPlaybackPosition
        
        await closeCurrentSession()
        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemId)
        
        let (session, source) = try await openSession(server: server, itemId: itemId, bookID: bookID)
        // Sync the length of the files actually played; the item duration can
        // include files the server excludes from playback.
        let sessionDuration = source.timeline.duration
        let startTime = source.timeline.clamp(resumePosition)
        configureSessionState(session: session, server: server, itemId: itemId,
                              duration: sessionDuration, startTime: startTime)
        activeTitle = title
        activeBookID = bookID
        startAppropriateTimer()
        AppLogger.sync.info("Session \(session.id, privacy: .private) started; streaming \(source.trackURLs.count) file(s) from \(source.identityURL.host ?? "unknown", privacy: .private)")
        return RemotePlaybackStart(
            source: source,
            chapters: session.chapters ?? [],
            resumePosition: startTime,
            sessionDuration: sessionDuration
        )
    }
    
    func closeCurrentSession() async {
        stopAllTimers()
        guard let sessionId = activeSessionId, let server = currentServer, let itemId = currentItemId else { return }
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        let hasUpdate = hasUnsyncedProgress(currentTime: currentTime, listened: listened)
        let bookID = activeBookID
        
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            if hasUpdate {
                backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
            }
            clearSession()
            return
        }
        
        do {
            if hasUpdate {
                try await api.closeSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId, currentTime: currentTime, timeListened: listened, duration: duration)
                ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
                if let bookID { PlaybackProgressTracker.shared.markSynced(bookID: bookID) }
            } else {
                // Nothing changed here: don't report a position that could
                // overwrite progress made on another device meanwhile.
                try await api.closeSessionWithoutUpdate(baseURL: server.normalizedURL, token: token, sessionId: sessionId)
            }
            AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at \(currentTime)s (total listened: \(listened)s, reported: \(hasUpdate))")
        } catch {
            AppLogger.sync.error("Failed to close session: \(error.localizedDescription, privacy: .private)")
            if hasUpdate {
                backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
            }
        }
        clearSession()
    }

    /// Whether this session has progress the server hasn't seen: time listened,
    /// or a position moved (for example by a seek) since the last sync.
    private func hasUnsyncedProgress(currentTime: Double, listened: Double) -> Bool {
        listened > 0 || abs(currentTime - lastSyncedTime) >= progressBackupEpsilon
    }

    private func backupProgress(server: ABSServer, itemId: String, currentTime: Double, listened: Double, duration: Double) {
        let changedAt = activeBookID.flatMap { PlaybackProgressTracker.shared.lastChange(bookID: $0) }
        ProgressBackupStore.shared.backup(
            serverURL: server.normalizedURL,
            itemId: itemId,
            currentTime: currentTime,
            timeListened: listened,
            duration: duration,
            changedAt: changedAt
        )
    }
    
    func syncProgress() async {
        await performSync(requireUnsyncedProgress: false)
    }
    
    func recoverPendingProgressIfNeeded(container: ModelContainer) async {
        await ProgressBackupStore.shared.recoverPendingForAllBooks(container: container)
    }
}

private extension PlaybackSessionManager {
    func handleAppDidEnterBackground() {
        PlaybackProgressTracker.shared.flush()
        guard activeSessionId != nil else { return }
        isInBackground = true
        performBackgroundSyncTask(named: "StoryCast.ProgressSync") { [weak self] in
            await self?.performSync(requireUnsyncedProgress: true)
        }
        stopSyncTimer()
        startBackgroundSyncTimer()
        AppLogger.sync.debug("Entered background — switched to 5-minute sync interval")
    }
    
    func handleAppWillEnterForeground() {
        guard activeSessionId != nil else { return }
        isInBackground = false
        isTerminating = false
        stopBackgroundSyncTimer()
        Task { await syncProgress() }
        startSyncTimer()
        AppLogger.sync.debug("Entered foreground — resumed 30-second sync interval")
    }
    
    func handleAppWillTerminate() {
        PlaybackProgressTracker.shared.flush()
        guard let sessionId = activeSessionId, let server = currentServer, let itemId = currentItemId else { return }
        isTerminating = true
        stopAllTimers()
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        let hasUpdate = hasUnsyncedProgress(currentTime: currentTime, listened: listened)
        
        performBackgroundSyncTask(named: "StoryCast.SessionSync") { [weak self] in
            guard let self else { return }
            guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
                if hasUpdate {
                    self.backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
                }
                self.clearSession()
                return
            }
            do {
                if hasUpdate {
                    try await self.api.closeSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId,
                                                    currentTime: currentTime, timeListened: listened, duration: duration)
                    ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
                } else {
                    try await self.api.closeSessionWithoutUpdate(baseURL: server.normalizedURL, token: token, sessionId: sessionId)
                }
                AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at termination")
            } catch {
                AppLogger.sync.error("Failed to close session at termination: \(error.localizedDescription, privacy: .private)")
                if hasUpdate {
                    self.backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
                }
            }
            self.clearSession()
        }
    }
    
    func handleNetworkTransition(toCellular isExpensive: Bool) async {
        guard activeSessionId != nil, currentServer != nil, currentItemId != nil else { return }
        let player = AudioPlayerService.shared
        guard player.isPlaying else {
            AppLogger.sync.debug("Network transitioned but player is paused — no reconnection needed")
            return
        }

        // The session and its per-file URLs stay valid across a network change,
        // and AVPlayer usually recovers on its own. Reload only if playback
        // stalled or failed, so a Wi-Fi/cellular switch doesn't discard buffered
        // and preloaded audio.
        let generation = player.loadGeneration
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard activeSessionId != nil, player.loadGeneration == generation else { return }
        let stalled = player.lastPlaybackError != nil || (player.isPlaying && !player.isAudioAdvancing)
        guard stalled, !player.isSeekPending else {
            AppLogger.sync.debug("Network transitioned to \(isExpensive ? "cellular" : "WiFi"); playback continued without reconnecting")
            return
        }
        await reconnectAfterNetworkChange(toCellular: isExpensive)
    }

    func reconnectAfterNetworkChange(toCellular isExpensive: Bool) async {
        guard let server = currentServer, let itemId = currentItemId else { return }
        let player = AudioPlayerService.shared
        let currentPosition = player.currentTime
        // Capture these BEFORE closeCurrentSession() runs, because
        // clearSession() resets them.
        let previousDuration = sessionDuration
        let title = activeTitle ?? "StoryCast"
        let bookID = activeBookID
        AppLogger.sync.info("Network transitioned to \(isExpensive ? "cellular" : "WiFi") and playback stalled — reconnecting")

        await closeCurrentSession()

        do {
            let source = try await reconnectSession(
                server: server,
                itemId: itemId,
                bookID: bookID,
                resumePosition: currentPosition,
                fallbackDuration: previousDuration
            )
            activeTitle = title
            activeBookID = bookID
            player.load(source: source, title: title, seekTo: currentPosition)
            player.play()
            AppLogger.sync.info("Successfully reconnected after network transition")
        } catch {
            AppLogger.sync.error("Failed to reconnect after network transition: \(error.localizedDescription, privacy: .private)")
            // Notify the user that reconnection failed
            NotificationCenter.default.post(name: .storyCastReconnectionFailed, object: nil, userInfo: ["error": error])
        }
    }

    func reconnectSession(server: ABSServer, itemId: String, bookID: UUID?, resumePosition: Double, fallbackDuration: TimeInterval) async throws -> PlaybackSource {
        let (session, source) = try await openSession(server: server, itemId: itemId, bookID: bookID)
        let duration = source.timeline.duration > 0 ? source.timeline.duration : fallbackDuration
        configureSessionState(session: session, server: server, itemId: itemId,
                              duration: duration,
                              startTime: resumePosition)
        startAppropriateTimer()
        AppLogger.sync.info("Session \(session.id, privacy: .private) reconnected")
        return source
    }
    
    /// Opens a play session and builds a source from every file the server
    /// lists, in play order. Each file URL is checked by the URL validator;
    /// if any file is missing data or fails validation, the session fails.
    func openSession(server: ABSServer, itemId: String, bookID: UUID?) async throws -> (ABSPlaybackSession, PlaybackSource) {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }
        AppLogger.sync.info("Starting playback session for item \(itemId, privacy: .private)")
        
        let session = try await api.startPlaybackSession(baseURL: server.normalizedURL, token: token, itemId: itemId)
        let tracks = PlaybackTimeline.playbackOrder(session.audioTracks, startOffset: \.startOffset)
        guard !tracks.isEmpty else { throw APIError.invalidResponse }

        var urls: [URL] = []
        var durations: [Double] = []
        var headers: [String: String] = [:]
        for track in tracks {
            guard let duration = track.duration, duration.isFinite, duration >= 0 else {
                throw APIError.invalidResponse
            }
            let contentUrl = track.contentUrl ?? track.ino.map { "/api/items/\(itemId)/file/\($0)" }
            guard let contentUrl else { throw APIError.invalidResponse }
            let stream = try await api.authenticatedStream(baseURL: server.normalizedURL, token: token, contentUrl: contentUrl)
            urls.append(stream.url)
            durations.append(duration)
            headers = stream.headers
        }
        guard let timeline = PlaybackTimeline(durations: durations),
              let source = PlaybackSource(
                bookID: bookID,
                identityURL: urls[0],
                trackURLs: urls,
                timeline: timeline,
                httpHeaders: headers
              ) else {
            throw APIError.invalidResponse
        }
        return (session, source)
    }
    
    func configureSessionState(session: ABSPlaybackSession, server: ABSServer, itemId: String, duration: Double, startTime: Double) {
        activeSessionId = session.id
        currentServer = server
        currentItemId = itemId
        sessionDuration = duration
        sessionStartTime = startTime
        lastSyncedTime = startTime
        lastObservedTime = startTime
        totalTimeListened = 0
    }
    
    func startAppropriateTimer() {
        #if canImport(UIKit)
        isInBackground = UIApplication.shared.applicationState == .background
        #endif
        isInBackground ? startBackgroundSyncTimer() : startSyncTimer()
    }
    
    func performSync(requireUnsyncedProgress: Bool) async {
        guard !isSyncing, !isSeeking, let sessionId = activeSessionId, let server = currentServer else { return }
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else { return }
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        
        if requireUnsyncedProgress {
            guard listened > 0 || abs(currentTime - lastSyncedTime) >= progressBackupEpsilon else { return }
            guard listened >= AudiobookshelfDefaults.minTimeListenedToSync else {
                if let itemId = currentItemId {
                    backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
                }
                AppLogger.sync.debug("Backed up pending progress while entering background: \(currentTime)s")
                return
            }
        } else {
            guard listened >= AudiobookshelfDefaults.minTimeListenedToSync else { return }
        }
        
        lastSyncError = nil
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            try await api.syncSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId, currentTime: currentTime, timeListened: listened, duration: duration)
            lastSyncedTime = currentTime
            // Only this sync's listening was reported; keep anything counted
            // while the request was in flight.
            totalTimeListened = max(0, totalTimeListened - listened)
            if let itemId = currentItemId {
                ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
            }
            if let bookID = activeBookID {
                PlaybackProgressTracker.shared.markSynced(bookID: bookID)
            }
            AppLogger.sync.debug("Synced progress: \(currentTime)s (listened \(listened)s)")
        } catch {
            lastSyncError = error
            if requireUnsyncedProgress, let itemId = currentItemId {
                backupProgress(server: server, itemId: itemId, currentTime: currentTime, listened: listened, duration: duration)
            }
            AppLogger.sync.error("Progress sync failed: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    func performBackgroundSyncTask(named taskName: String, operation: @escaping @MainActor () async -> Void) {
        #if canImport(UIKit)
        // End any previous leaked background task
        if activeBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(activeBackgroundTaskID)
            activeBackgroundTaskID = .invalid
        }
        
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: taskName) { [weak self] in
            // Expiration can run on an arbitrary queue and must end the task
            // before returning, or iOS terminates the app.
            AppLogger.sync.warning("Background task \(taskName) expired")
            UIApplication.shared.endBackgroundTask(taskID)
            Task { @MainActor [weak self] in
                guard let self, self.activeBackgroundTaskID == taskID else { return }
                self.activeBackgroundTaskID = .invalid
            }
        }
        activeBackgroundTaskID = taskID
        
        guard taskID != .invalid else {
            Task { @MainActor in await operation() }
            return
        }
        Task { @MainActor in
            await operation()
            UIApplication.shared.endBackgroundTask(taskID)
            if self.activeBackgroundTaskID == taskID {
                self.activeBackgroundTaskID = .invalid
            }
        }
        #else
        Task { @MainActor in await operation() }
        #endif
    }
    
    func clearSession() {
        activeSessionId = nil
        currentServer = nil
        currentItemId = nil
        activeTitle = nil
        activeBookID = nil
        sessionDuration = 0
        sessionStartTime = 0
        lastSyncedTime = 0
        totalTimeListened = 0
        lastObservedTime = 0
        lastListeningTick = nil
        isInBackground = false
        isTerminating = false
        isSeeking = false
        isSeekingClearTask?.cancel()
        isSeekingClearTask = nil
    }
    
    func stopAllTimers() {
        syncTimer?.invalidate(); syncTimer = nil
        backgroundSyncTimer?.invalidate(); backgroundSyncTimer = nil
    }
    
    func startSyncTimer() {
        syncTimer?.invalidate()
        let capturedSessionId = activeSessionId
        syncTimer = Timer.scheduledTimer(withTimeInterval: AudiobookshelfDefaults.progressSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let capturedSessionId, self.activeSessionId == capturedSessionId, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }
    
    func startBackgroundSyncTimer() {
        backgroundSyncTimer?.invalidate()
        let capturedSessionId = activeSessionId
        backgroundSyncTimer = Timer.scheduledTimer(withTimeInterval: AudiobookshelfDefaults.backgroundProgressSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let capturedSessionId, self.activeSessionId == capturedSessionId, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }
    
    func stopSyncTimer() { syncTimer?.invalidate(); syncTimer = nil }
    func stopBackgroundSyncTimer() { backgroundSyncTimer?.invalidate(); backgroundSyncTimer = nil }
}

#if DEBUG
extension PlaybackSessionManager {
    var debugTotalTimeListened: Double { totalTimeListened }
    var debugLastObservedTime: Double { lastObservedTime }
    var debugIsSeeking: Bool { isSeeking }

    func debugSetLastObservedTime(_ time: Double) { lastObservedTime = time }
    func debugResetListenedTime() { totalTimeListened = 0 }
    var debugSessionDuration: Double { sessionDuration }
    var debugLastSyncedTime: Double { lastSyncedTime }
    var debugActiveTitle: String? { activeTitle }

    func debugOverrideAPI(_ api: AudiobookshelfAPI?) { apiOverride = api }
    func debugResetSession() {
        stopAllTimers()
        clearSession()
    }
    func debugClearSeeking() {
        isSeekingClearTask?.cancel()
        isSeekingClearTask = nil
        isSeeking = false
    }
}
#endif
