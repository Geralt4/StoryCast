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
    /// Whether the resume position is this device's or the server's (newer) one.
    let resumeSource: ResumePositionResolver.Decision.Source
    /// When the server's progress was last updated, on this device's clock.
    let serverUpdatedAt: Date?
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
    private var sessionlessTarget: SessionlessTarget?
    private var sessionlessTimer: Timer?
    private var lastSessionlessReport: (date: Date, position: Double)?
    private var isReportingSessionless = false
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
                guard let self else { return }
                self.lastListeningTick = nil
                if let target = self.sessionlessTarget, player.currentBookID != target.bookID {
                    self.endSessionlessReporting()
                }
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying {
                    self.startSessionlessTimer()
                } else {
                    self.stopSessionlessTimer()
                    Task { @MainActor in await self.reportSessionlessProgress(force: true) }
                }
            }
            .store(in: &cancellables)
        player.$playbackDidReachEnd
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in await self?.reportSessionlessProgress(force: true, isFinished: true) }
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

    // MARK: - Progress for downloaded books

    private struct SessionlessTarget {
        let bookID: UUID
        let itemId: String
        let serverURL: String
        let duration: Double
    }

    /// Downloaded remote books play without an Audiobookshelf session; their
    /// progress is sent with `PATCH /api/me/progress` instead, while playing
    /// (every 30 s) and when playback pauses, ends or the app goes to the
    /// background. It keeps working after the player screen is closed.
    func beginSessionlessReporting(bookID: UUID, itemId: String, serverURL: String, duration: Double) {
        sessionlessTarget = SessionlessTarget(bookID: bookID, itemId: itemId, serverURL: serverURL, duration: duration)
        lastSessionlessReport = nil
        if AudioPlayerService.shared.isPlaying {
            startSessionlessTimer()
        }
    }

    func endSessionlessReporting() {
        sessionlessTarget = nil
        lastSessionlessReport = nil
        stopSessionlessTimer()
    }

    /// Sends the position of the downloaded book being played, when it has
    /// changed here and the file covers the whole book. `force` skips the
    /// 30-second throttle; `isFinished` marks the book finished.
    func reportSessionlessProgress(force: Bool, isFinished: Bool = false) async {
        guard let target = sessionlessTarget, !isReportingSessionless else { return }
        let player = AudioPlayerService.shared
        guard player.currentBookID == target.bookID,
              player.currentSource?.isLocal == true,
              player.currentSource?.coversWholeBook == true,
              activeRemoteItemId != target.itemId else { return }
        let tracker = PlaybackProgressTracker.shared
        guard isFinished || tracker.isDirty(bookID: target.bookID) else { return }
        let position = player.currentTime
        guard position.isFinite else { return }
        if !force, !isFinished, let last = lastSessionlessReport,
           Date().timeIntervalSince(last.date) < AudiobookshelfDefaults.progressSyncInterval || abs(position - last.position) < 1 {
            return
        }

        isReportingSessionless = true
        defer { isReportingSessionless = false }
        let changedAt = tracker.lastChange(bookID: target.bookID)
        let backup = {
            ProgressBackupStore.shared.backup(
                serverURL: target.serverURL,
                itemId: target.itemId,
                currentTime: position,
                timeListened: 0,
                duration: target.duration,
                changedAt: changedAt
            )
        }
        guard NetworkMonitor.shared.isConnected,
              let token = await AudiobookshelfAuth.shared.token(for: target.serverURL) else {
            backup()
            return
        }
        do {
            try await api.updateProgress(
                baseURL: target.serverURL,
                token: token,
                itemId: target.itemId,
                currentTime: position,
                duration: target.duration,
                isFinished: isFinished ? true : nil
            )
            lastSessionlessReport = (Date(), position)
            tracker.markSynced(bookID: target.bookID, through: changedAt)
            ProgressBackupStore.shared.clear(serverURL: target.serverURL, itemId: target.itemId)
            AppLogger.sync.debug("Reported downloaded-book progress: \(position)s")
        } catch {
            AppLogger.sync.error("Failed to report downloaded-book progress: \(error.localizedDescription, privacy: .private)")
            backup()
        }
    }

    private func startSessionlessTimer() {
        guard sessionlessTarget != nil, sessionlessTimer == nil else { return }
        sessionlessTimer = Timer.scheduledTimer(withTimeInterval: AudiobookshelfDefaults.progressSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reportSessionlessProgress(force: false)
            }
        }
    }

    private func stopSessionlessTimer() {
        sessionlessTimer?.invalidate()
        sessionlessTimer = nil
    }

    func isCurrentSession(for book: Book) -> Bool {
        guard book.isRemote, let itemId = book.remoteItemId, let serverId = book.serverId else { return false }
        return currentItemId == itemId && currentServer?.id == serverId
    }
    
    /// Opens a play session and decides where to resume: this device's
    /// position (`localPosition`, or the book's saved one) or the server's,
    /// whichever is newer.
    func startSession(for book: Book, server: ABSServer, localPosition: Double? = nil) async throws -> RemotePlaybackStart {
        guard let itemId = book.remoteItemId else { throw APIError.noActiveSession }
        let bookID = book.id
        let title = book.title
        let tracker = PlaybackProgressTracker.shared
        let local = ResumePositionResolver.Local(
            position: localPosition ?? book.lastPlaybackPosition,
            changedAt: tracker.lastChange(bookID: bookID),
            isDirty: tracker.isDirty(bookID: bookID)
        )
        
        await closeCurrentSession()

        // Ask for the server's progress while the session opens.
        let snapshotTask = Task { @MainActor in await self.fetchProgressSnapshot(server: server, itemId: itemId) }
        let session: ABSPlaybackSession
        let source: PlaybackSource
        do {
            (session, source) = try await openSession(server: server, itemId: itemId, bookID: bookID)
        } catch {
            snapshotTask.cancel()
            throw error
        }
        let fetched = await snapshotTask.value
        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemId, serverProgress: fetched)
        let serverProgress: ServerProgressSnapshot?
        switch fetched {
        case .some(let snapshot):
            serverProgress = snapshot
        case .none:
            // The progress couldn't be fetched, but the session still reports
            // the server's position (without a timestamp).
            serverProgress = session.currentTime.map {
                ServerProgressSnapshot(currentTime: $0, duration: nil, isFinished: false, lastUpdate: nil, serverClockOffset: nil)
            }
        }
        let decision = ResumePositionResolver.resolve(
            local: local,
            server: serverProgress,
            timelineDuration: source.timeline.duration
        )

        // Sync the length of the files actually played; the item duration can
        // include files the server excludes from playback.
        let sessionDuration = source.timeline.duration
        let startTime = decision.position
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
            resumeSource: decision.source,
            serverUpdatedAt: serverProgress?.lastUpdateOnDeviceClock,
            sessionDuration: sessionDuration
        )
    }

    /// The server's progress for an item: `.some(nil)` when it has none,
    /// nil when it couldn't be fetched.
    func fetchProgressSnapshot(server: ABSServer, itemId: String) async -> ServerProgressSnapshot?? {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else { return nil }
        do {
            return .some(try await api.fetchProgressSnapshot(baseURL: server.normalizedURL, token: token, itemId: itemId))
        } catch {
            AppLogger.sync.debug("Couldn't fetch server progress: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
    
    func closeCurrentSession() async {
        stopAllTimers()
        guard let sessionId = activeSessionId, let server = currentServer, let itemId = currentItemId else { return }
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        let hasUpdate = hasUnsyncedProgress(currentTime: currentTime, listened: listened)
        let bookID = activeBookID
        let changedAt = bookID.flatMap { PlaybackProgressTracker.shared.lastChange(bookID: $0) }
        
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
                if let bookID { PlaybackProgressTracker.shared.markSynced(bookID: bookID, through: changedAt) }
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
        if sessionlessTarget != nil {
            performBackgroundSyncTask(named: "StoryCast.DownloadedProgressSync") { [weak self] in
                await self?.reportSessionlessProgress(force: true)
            }
        }
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
        let changedAt = activeBookID.flatMap { PlaybackProgressTracker.shared.lastChange(bookID: $0) }
        
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
                PlaybackProgressTracker.shared.markSynced(bookID: bookID, through: changedAt)
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
    var debugHasSessionlessTarget: Bool { sessionlessTarget != nil }
    var debugLastSyncedTime: Double { lastSyncedTime }
    var debugActiveTitle: String? { activeTitle }

    func debugOverrideAPI(_ api: AudiobookshelfAPI?) { apiOverride = api }
    func debugResetSession() {
        stopAllTimers()
        clearSession()
        endSessionlessReporting()
    }
    func debugClearSeeking() {
        isSeekingClearTask?.cancel()
        isSeekingClearTask = nil
        isSeeking = false
    }
}
#endif
