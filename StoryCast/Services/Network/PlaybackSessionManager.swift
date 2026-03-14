import Foundation
import Combine
import SwiftData
import os
#if canImport(UIKit)
import UIKit
#endif

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
        AudioPlayerService.shared.$currentTime
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] newTime in
                guard let self else { return }
                if AudioPlayerService.shared.isPlaying && newTime > self.lastObservedTime && !self.isSeeking {
                    self.totalTimeListened += newTime - self.lastObservedTime
                }
                if self.isSeeking { self.isSeeking = false }
                self.lastObservedTime = newTime
            }
            .store(in: &cancellables)
        
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [self] in self?.handleAppDidEnterBackground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [self] in self?.handleAppWillEnterForeground() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [self] in self?.handleAppWillTerminate() }
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
    
    func isCurrentSession(for book: Book) -> Bool {
        guard book.isRemote, let itemId = book.remoteItemId, let serverId = book.serverId else { return false }
        return currentItemId == itemId && currentServer?.id == serverId
    }
    
    func startSession(for book: Book, server: ABSServer) async throws -> AuthenticatedStream {
        guard let itemId = book.remoteItemId else { throw APIError.noActiveSession }
        
        await closeCurrentSession()
        await ProgressBackupStore.shared.attemptRecovery(server: server, itemId: itemId)
        
        let (session, stream) = try await openSession(server: server, itemId: itemId)
        configureSessionState(session: session, server: server, itemId: itemId,
                              duration: session.duration ?? book.duration,
                              startTime: session.currentTime ?? book.lastPlaybackPosition)
        startAppropriateTimer()
        AppLogger.sync.info("Session \(session.id, privacy: .private) started; streaming from \(stream.url.host ?? "unknown", privacy: .private)")
        return stream
    }
    
    func closeCurrentSession() async {
        stopAllTimers()
        guard let sessionId = activeSessionId, let server = currentServer, let itemId = currentItemId else { return }
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            clearSession()
            return
        }
        
        do {
            try await AudiobookshelfAPI.shared.closeSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId, currentTime: currentTime, timeListened: listened, duration: duration)
            ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at \(currentTime)s (total listened: \(listened)s)")
        } catch {
            AppLogger.sync.error("Failed to close session: \(error.localizedDescription, privacy: .private)")
            ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
        }
        clearSession()
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
        stopBackgroundSyncTimer()
        Task { await syncProgress() }
        startSyncTimer()
        AppLogger.sync.debug("Entered foreground — resumed 30-second sync interval")
    }
    
    func handleAppWillTerminate() {
        guard let sessionId = activeSessionId, let server = currentServer, let itemId = currentItemId else { return }
        isTerminating = true
        stopAllTimers()
        
        performBackgroundSyncTask(named: "StoryCast.SessionSync") { [weak self] in
            guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
                ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId,
                                                   currentTime: AudioPlayerService.shared.currentTime,
                                                   timeListened: self?.totalTimeListened ?? 0,
                                                   duration: self?.sessionDuration ?? 0)
                await self?.clearSession()
                return
            }
            do {
                try await AudiobookshelfAPI.shared.closeSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId,
                                                                 currentTime: AudioPlayerService.shared.currentTime,
                                                                 timeListened: self?.totalTimeListened ?? 0,
                                                                 duration: self?.sessionDuration ?? 0)
                ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
                AppLogger.sync.info("Session \(sessionId, privacy: .private) closed at termination")
            } catch {
                AppLogger.sync.error("Failed to close session at termination: \(error.localizedDescription, privacy: .private)")
                ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId,
                                                   currentTime: AudioPlayerService.shared.currentTime,
                                                   timeListened: self?.totalTimeListened ?? 0,
                                                   duration: self?.sessionDuration ?? 0)
            }
            await self?.clearSession()
        }
    }
    
    func handleNetworkTransition(toCellular isExpensive: Bool) async {
        guard activeSessionId != nil, let server = currentServer, let itemId = currentItemId else { return }
        guard AudioPlayerService.shared.isPlaying else {
            AppLogger.sync.debug("Network transitioned but player is paused — no reconnection needed")
            return
        }
        
        let currentPosition = AudioPlayerService.shared.currentTime
        AppLogger.sync.info("Network transitioned to \(isExpensive ? "cellular" : "WiFi") — attempting reconnection")
        
        await closeCurrentSession()
        
        do {
            _ = try await reconnectSession(server: server, itemId: itemId, resumePosition: currentPosition)
            AudioPlayerService.shared.seek(to: currentPosition)
            AudioPlayerService.shared.play()
            AppLogger.sync.info("Successfully reconnected after network transition")
        } catch {
            AppLogger.sync.error("Failed to reconnect after network transition: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    func reconnectSession(server: ABSServer, itemId: String, resumePosition: Double) async throws -> AuthenticatedStream {
        let (session, stream) = try await openSession(server: server, itemId: itemId)
        configureSessionState(session: session, server: server, itemId: itemId,
                              duration: session.duration ?? sessionDuration,
                              startTime: session.currentTime ?? resumePosition)
        startSyncTimer()
        AppLogger.sync.info("Session \(session.id, privacy: .private) reconnected")
        return stream
    }
    
    func openSession(server: ABSServer, itemId: String) async throws -> (ABSPlaybackSession, AuthenticatedStream) {
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            throw APIError.tokenMissing
        }
        AppLogger.sync.info("Starting playback session for item \(itemId, privacy: .private)")
        
        let session = try await AudiobookshelfAPI.shared.startPlaybackSession(baseURL: server.normalizedURL, token: token, itemId: itemId)
        guard let firstTrack = session.audioTracks.first, let contentUrl = firstTrack.contentUrl else {
            throw APIError.invalidResponse
        }
        let stream = try await AudiobookshelfAPI.shared.authenticatedStream(baseURL: server.normalizedURL, token: token, contentUrl: contentUrl)
        return (session, stream)
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
        guard !isSyncing, let sessionId = activeSessionId, let server = currentServer else { return }
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else { return }
        
        let currentTime = AudioPlayerService.shared.currentTime
        let listened = totalTimeListened
        let duration = sessionDuration
        
        if requireUnsyncedProgress {
            guard listened > 0 || abs(currentTime - lastSyncedTime) >= progressBackupEpsilon else { return }
            guard listened >= AudiobookshelfDefaults.minTimeListenedToSync else {
                if let itemId = currentItemId {
                    ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
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
            try await AudiobookshelfAPI.shared.syncSession(baseURL: server.normalizedURL, token: token, sessionId: sessionId, currentTime: currentTime, timeListened: listened, duration: duration)
            lastSyncedTime = currentTime
            totalTimeListened = 0
            if let itemId = currentItemId {
                ProgressBackupStore.shared.clear(serverURL: server.normalizedURL, itemId: itemId)
            }
            AppLogger.sync.debug("Synced progress: \(currentTime)s (listened \(listened)s)")
        } catch {
            lastSyncError = error
            if requireUnsyncedProgress, let itemId = currentItemId {
                ProgressBackupStore.shared.backup(serverURL: server.normalizedURL, itemId: itemId, currentTime: currentTime, timeListened: listened, duration: duration)
            }
            AppLogger.sync.error("Progress sync failed: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    func performBackgroundSyncTask(named taskName: String, operation: @escaping @MainActor () async -> Void) {
        #if canImport(UIKit)
        let taskID = UIApplication.shared.beginBackgroundTask(withName: taskName, expirationHandler: nil)
        guard taskID != .invalid else {
            Task { @MainActor in await operation() }
            return
        }
        Task { @MainActor in
            await operation()
            UIApplication.shared.endBackgroundTask(taskID)
        }
        #else
        Task { @MainActor in await operation() }
        #endif
    }
    
    func clearSession() {
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
    
    func stopAllTimers() {
        syncTimer?.invalidate(); syncTimer = nil
        backgroundSyncTimer?.invalidate(); backgroundSyncTimer = nil
    }
    
    func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: AudiobookshelfDefaults.progressSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionId != nil, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }
    
    func startBackgroundSyncTimer() {
        backgroundSyncTimer?.invalidate()
        backgroundSyncTimer = Timer.scheduledTimer(withTimeInterval: AudiobookshelfDefaults.backgroundProgressSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionId != nil, !self.isTerminating, !self.isSyncing else { return }
                await self.syncProgress()
            }
        }
    }
    
    func stopSyncTimer() { syncTimer?.invalidate(); syncTimer = nil }
    func stopBackgroundSyncTimer() { backgroundSyncTimer?.invalidate(); backgroundSyncTimer = nil }
}