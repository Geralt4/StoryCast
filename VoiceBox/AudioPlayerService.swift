import AVFoundation
import Foundation
import Combine
import os
#if os(iOS)
import MediaPlayer
import UIKit
#endif

// Import local modules for the project
import SwiftUI

@MainActor
class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var playbackRate: Float = 1.0
    @Published var playbackDidReachEnd = false
    
    private(set) var currentURL: URL?
    
    // Now Playing metadata storage
    private var nowPlayingTitle: String = ""
    private var nowPlayingDuration: Double = 0.0
    private var nowPlayingArtwork: UIImage?

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var cachedPlaybackSettings = PlaybackSettings.load()
    private var settingsObserver: Any?
    private var pendingSeekTime: Double?
    private var playerItemObserver: NSKeyValueObservation?
    private var wasPlayingBeforeInterruption = false
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var durationLoadTask: Task<Void, Never>?
    private var endOfPlaybackObserver: Any?
    private let preferredTimescale: CMTimeScale = 600
    private var isNowPlayingConfigured = false
    #if os(iOS)
    private var appLifecycleObservers: [Any] = []
    private var isAudioSessionActive = false
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {
        setupAudioSession()
        isNowPlayingConfigured = true // Set before setupNowPlaying so updateSkipIntervals guard passes
        setupNowPlaying()
        setupAudioSessionObservers()
        observePlaybackSettingsChanges()
        playbackRate = cachedPlaybackSettings.defaultPlaybackSpeed
    }

    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Configure audio session for optimal background audiobook playback
            // Using .spokenAudio mode and .longFormAudio policy for proper lock screen/Control Center support
            // Note: longFormAudio policy doesn't support duckOthers, allowAirPlay, allowBluetoothHFP options
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            // Activate the audio session to enable background playback
            try session.setActive(true)
            AppLogger.playback.info("Audio session configured successfully for background playback")
        } catch {
            AppLogger.playback.error("Failed to set up audio session: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }

    private func ensureAudioSessionActive() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Ensure audio session is properly configured for background playback
            // Note: longFormAudio policy doesn't support duckOthers, allowAirPlay, allowBluetoothHFP options
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            isAudioSessionActive = true
        } catch {
            AppLogger.playback.error("Failed to activate audio session: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }
    
    #if os(iOS)
    private func ensurePlayerReadyForRemotePlay() -> Bool {
        // Make sure we have a valid player
        guard player != nil else {
            AppLogger.remoteCommand.error("ensurePlayerReadyForRemotePlay: No player available")
            return false
        }
        
        // Ensure audio session is active with proper configuration
        do {
            let session = AVAudioSession.sharedInstance()
            // Note: longFormAudio policy doesn't support duckOthers, allowAirPlay, allowBluetoothHFP options
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
            AppLogger.remoteCommand.info("ensurePlayerReadyForRemotePlay: Audio session activated")
            return true
        } catch {
            AppLogger.remoteCommand.error("ensurePlayerReadyForRemotePlay: Failed to activate audio session: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
    
    #endif

    private func ensureNowPlayingConfigured() {
        guard !isNowPlayingConfigured else { return }
        isNowPlayingConfigured = true
        setupNowPlaying()
    }

    #if os(iOS)
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskId == .invalid else {
#if DEBUG
            print("📱 [BG] Task already active (ID: \(backgroundTaskId.rawValue))")
#endif
            AppLogger.playback.debug("beginBackgroundTaskIfNeeded: task already active")
            return
        }
#if DEBUG
        print("📱 [BG] ⏱️ Starting background task at \(Date())")
#endif
        AppLogger.playback.info("beginBackgroundTaskIfNeeded: starting background task")
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "VoiceBoxPlayback") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
#if DEBUG
                print("📱 [BG] ⚠️ BACKGROUND TASK EXPIRED at \(Date())")
#endif
                AppLogger.playback.warning("Background task expired; ending task.")
                self.endBackgroundTaskIfNeeded()
            }
        }
        if backgroundTaskId == .invalid {
#if DEBUG
            print("📱 [BG] ❌ Failed to start background task")
#endif
            AppLogger.playback.warning("Failed to start background task.")
        } else {
#if DEBUG
            print("📱 [BG] ✅ Task started with ID: \(backgroundTaskId.rawValue)")
#endif
            AppLogger.playback.info("beginBackgroundTaskIfNeeded: background task started with id \(self.backgroundTaskId.rawValue)")
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskId != .invalid else { 
#if DEBUG
            print("📱 [BG] No active task to end")
#endif
            return 
        }
#if DEBUG
        print("📱 [BG] 🛑 Ending background task (ID: \(backgroundTaskId.rawValue)) at \(Date())")
#endif
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
    #endif

    private func setupNowPlaying() {
#if DEBUG
        print("🎛️ [REMOTECTRL] Setting up Now Playing at \(Date())")
#endif
        #if os(iOS)
        let commandCenter = MPRemoteCommandCenter.shared()
#if DEBUG
        print("🎛️ [REMOTECTRL] Registering remote command targets")
#endif
        // Targets registered once; singleton lives for app lifecycle.

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
#if DEBUG
            let thread = Thread.current
            print("🎮 [REMOTE] ▶️ PLAY command received at \(Date()) on thread: \(thread.description)")
#endif
            AppLogger.remoteCommand.info("playCommand received")
            
            // All MainActor-isolated work is dispatched asynchronously
            // Audio session activation and player readiness are handled inside the Task
            Task { @MainActor in
#if DEBUG
                print("🎮 [REMOTE] 🎯 MainActor task executing at \(Date())")
#endif
                AppLogger.remoteCommand.info("playCommand: MainActor task started")
                guard self.ensurePlayerReadyForRemotePlay() else {
#if DEBUG
                    print("🎮 [REMOTE] ❌ Player not ready for remote play")
#endif
                    return
                }
                self.beginBackgroundTaskIfNeeded()
                self.play()
#if DEBUG
                print("🎮 [REMOTE] ✅ play() completed at \(Date())")
#endif
                AppLogger.remoteCommand.info("playCommand: play() completed")
            }
#if DEBUG
            print("🎮 [REMOTE] 🏁 Returning .success at \(Date())")
#endif
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
#if DEBUG
            print("🎮 [REMOTE] ⏸️ PAUSE command received at \(Date())")
#endif
            AppLogger.remoteCommand.info("pauseCommand received")
            
            Task { @MainActor in
#if DEBUG
                print("🎮 [REMOTE] 🎯 MainActor task executing at \(Date())")
#endif
                self.pause()
#if DEBUG
                print("🎮 [REMOTE] ✅ pause() completed at \(Date())")
#endif
                AppLogger.remoteCommand.info("pauseCommand: pause() completed")
            }
#if DEBUG
            print("🎮 [REMOTE] 🏁 Returning .success at \(Date())")
#endif
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
#if DEBUG
            print("🎮 [REMOTE] 🔀 TOGGLE command received at \(Date())")
#endif
            AppLogger.remoteCommand.info("togglePlayPauseCommand received")
            
            // All MainActor-isolated state reads and mutations happen inside the Task
            Task { @MainActor in
#if DEBUG
                print("🎮 [REMOTE] 🎯 MainActor task executing at \(Date())")
#endif
                if self.isPlaying {
#if DEBUG
                    print("🎮 [REMOTE] ⏸️ Pause branch in toggle")
#endif
                    AppLogger.remoteCommand.info("togglePlayPauseCommand: pausing")
                    self.pause()
                } else {
#if DEBUG
                    print("🎮 [REMOTE] ▶️ Play branch in toggle")
#endif
                    AppLogger.remoteCommand.info("togglePlayPauseCommand: playing")
                    guard self.ensurePlayerReadyForRemotePlay() else {
#if DEBUG
                        print("🎮 [REMOTE] ❌ Player not ready for toggle play")
#endif
                        return
                    }
                    self.beginBackgroundTaskIfNeeded()
                    self.play()
                }
#if DEBUG
                print("🎮 [REMOTE] ✅ Toggle completed at \(Date())")
#endif
            }
#if DEBUG
            print("🎮 [REMOTE] 🏁 Returning .success at \(Date())")
#endif
            return .success
        }

        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
            AppLogger.remoteCommand.info("skipForwardCommand received")
            
            Task { @MainActor in
                self.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
            AppLogger.remoteCommand.info("skipBackwardCommand received")
            
            Task { @MainActor in
                self.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .noActionableNowPlayingItem
            }
            AppLogger.remoteCommand.info("changePlaybackPositionCommand received: position=\(event.positionTime, privacy: .private)")
            
            Task { @MainActor in
                self.seek(to: event.positionTime)
            }
            return .success
        }

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
#if DEBUG
        print("🎛️ [REMOTECTRL] All remote commands enabled")
#endif

        // Set preferred skip intervals
        updateSkipIntervals()
#if DEBUG
        print("🎛️ [REMOTECTRL] ✅ Now Playing setup complete at \(Date())")
#endif
        #endif
    }

    func handleAppDidEnterBackground() {
#if DEBUG
        print("📱 [LIFECYCLE] 🌙 didEnterBackground at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else {
#if DEBUG
            print("📱 [LIFECYCLE] Not playing, ending background task")
#endif
            endBackgroundTaskIfNeeded()
            return
        }
#if DEBUG
        print("📱 [LIFECYCLE] Playing - ensuring audio session active")
#endif
        ensureAudioSessionActive()
#if DEBUG
        print("📱 [LIFECYCLE] Playing - starting background task")
#endif
        beginBackgroundTaskIfNeeded()
#if DEBUG
        print("📱 [LIFECYCLE] Playing - updating playback rate")
#endif
        updatePlaybackRate()
        // Refresh NowPlayingInfo before app goes to background
#if DEBUG
        print("📱 [LIFECYCLE] Playing - refreshing now playing info")
#endif
        refreshNowPlayingInfo()
        #endif
    }

    func handleAppDidBecomeActive() {
#if DEBUG
        print("📱 [LIFECYCLE] ☀️ didBecomeActive at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else {
#if DEBUG
            print("📱 [LIFECYCLE] Not playing, ending background task")
#endif
            endBackgroundTaskIfNeeded()
            return
        }
#if DEBUG
        print("📱 [LIFECYCLE] Playing - ensuring audio session active")
#endif
        ensureAudioSessionActive()
#if DEBUG
        print("📱 [LIFECYCLE] Playing - updating playback rate")
#endif
        updatePlaybackRate()
        // Refresh NowPlayingInfo when app becomes active
#if DEBUG
        print("📱 [LIFECYCLE] Playing - refreshing now playing info")
#endif
        refreshNowPlayingInfo()
        #endif
    }

    private func setupAudioSessionObservers() {
        #if os(iOS)
        // Handle audio interruptions (e.g., phone calls) - but NOT screen lock interruptions
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo else { return }
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
#if DEBUG
            print("🔊 [SESSION] Audio interruption: type=\(typeValue), options=\(optionsValue) at \(Date())")
#endif
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let type = AVAudioSession.InterruptionType(rawValue: typeValue) ?? .ended
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                
                AppLogger.playback.info("Audio interruption: type=\(typeValue), options=\(optionsValue)")
                
                if type == .began {
#if DEBUG
                    print("🔊 [SESSION] Interruption began - wasPlaying: \(self.isPlaying)")
#endif
                    // For interruptions (phone calls, Siri, etc.), pause playback and remember state
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    if self.isPlaying {
                        // Pause the player but DON'T end background task
                        // We need to keep it alive to resume after interruption
#if DEBUG
                        print("🔊 [SESSION] Pausing player due to interruption")
#endif
                        self.player?.pause()
                        self.updatePlaybackState()
                        self.updatePlaybackRate()
                        self.isAudioSessionActive = false
                        AppLogger.playback.info("Paused due to audio interruption (keeping background task)")
                    }
                } else if type == .ended {
#if DEBUG
                    print("🔊 [SESSION] Interruption ended - shouldResume: \(options.contains(.shouldResume)), wasPlaying: \(self.wasPlayingBeforeInterruption)")
#endif
                    AppLogger.playback.info("Audio interruption ended - shouldResume: \(options.contains(.shouldResume)), wasPlaying: \(self.wasPlayingBeforeInterruption)")
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        // Re-activate audio session and resume playback
#if DEBUG
                        print("🔊 [SESSION] Resuming playback after interruption")
#endif
                        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                        self.isAudioSessionActive = true
                        self.play()
                    }
                }
            }
        }

        // Handle route changes (e.g., headphones disconnected)
        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo else { return }
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
#if DEBUG
            print("🔊 [SESSION] Route change: reason=\(reasonValue) at \(Date())")
#endif
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown
                if reason == .oldDeviceUnavailable {
#if DEBUG
                    print("🔊 [SESSION] Old device unavailable - pausing playback")
#endif
                    // Headphones/Bluetooth disconnected, pause playback
                    self.pause()
                }
            }
        }

        let center = NotificationCenter.default
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillResignActive()
            }
        })
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
            }
        })
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillEnterForeground()
            }
        })
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        })
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProtectedDataWillBecomeUnavailable()
            }
        })
        appLifecycleObservers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProtectedDataDidBecomeAvailable()
            }
        })
        #endif
    }

    func handleAppWillResignActive() {
#if DEBUG
        print("📱 [LIFECYCLE] ⏳ willResignActive at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else { return }
        ensureAudioSessionActive()
        beginBackgroundTaskIfNeeded()
        updatePlaybackRate()
        #endif
    }

    func handleAppWillEnterForeground() {
#if DEBUG
        print("📱 [LIFECYCLE] 🌅 willEnterForeground at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else { return }
        ensureAudioSessionActive()
        updatePlaybackRate()
        #endif
    }

    func handleProtectedDataWillBecomeUnavailable() {
#if DEBUG
        print("📱 [LIFECYCLE] 🔒 protectedDataWillBecomeUnavailable at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else { return }
        ensureAudioSessionActive()
        beginBackgroundTaskIfNeeded()
        updatePlaybackRate()
        #endif
    }

    func handleProtectedDataDidBecomeAvailable() {
#if DEBUG
        print("📱 [LIFECYCLE] 🔓 protectedDataDidBecomeAvailable at \(Date()) - isPlaying: \(isPlaying)")
#endif
        #if os(iOS)
        guard isPlaying else { return }
        ensureAudioSessionActive()
        updatePlaybackRate()
        #endif
    }

    private func observePlaybackSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let settings = PlaybackSettings.load()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let previousPlaybackRate = self.cachedPlaybackSettings.defaultPlaybackSpeed
                self.cachedPlaybackSettings = settings
                if settings.defaultPlaybackSpeed != previousPlaybackRate {
                    self.playbackRate = settings.defaultPlaybackSpeed
                    if self.isPlaying {
                        self.player?.rate = self.playbackRate
                    }
                    self.updatePlaybackRate()
                }
                self.updateSkipIntervals()
            }
        }
    }

    private func updateSkipIntervals() {
        guard isNowPlayingConfigured else { return }
        #if os(iOS)
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: cachedPlaybackSettings.skipForwardSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: cachedPlaybackSettings.skipBackwardSeconds)]
        #endif
    }

    func updateNowPlayingInfo(title: String, duration: Double, currentTime: Double, artwork: UIImage? = nil) {
        #if os(iOS)
        // Store metadata for future updates
        nowPlayingTitle = title
        nowPlayingDuration = duration
        nowPlayingArtwork = artwork
        
        refreshNowPlayingInfo(withCurrentTime: currentTime)
        #endif
    }
    
    func updateNowPlayingTitle(_ title: String) {
        #if os(iOS)
        nowPlayingTitle = title
        refreshNowPlayingInfo()
        #endif
    }
    
    #if os(iOS)
    private func refreshNowPlayingInfo(withCurrentTime currentTime: Double? = nil) {
        // Always update Now Playing info, even if title is empty (to ensure system knows media is playing)
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = nowPlayingTitle.isEmpty ? "VoiceBox" : nowPlayingTitle
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = nowPlayingDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime ?? self.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
        
        if let artwork = nowPlayingArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { size in
                return artwork
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
#if DEBUG
        print("🎵 [NOWPLAYING] Refreshed at \(Date()) - title: \(nowPlayingTitle.isEmpty ? "VoiceBox" : nowPlayingTitle), isPlaying: \(isPlaying), rate: \(isPlaying ? playbackRate : 0.0)")
#endif
        AppLogger.playback.debug("Refreshed Now Playing info; isPlaying: \(self.isPlaying)")
    }
    #endif

    private func updatePlaybackRate() {
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    func loadAudio(url: URL, title: String, duration: Double, seekTo time: Double? = nil) {
#if DEBUG
        print("📂 [LOAD] Loading audio at \(Date()) - title: \(title), duration: \(duration), seekTo: \(time ?? 0.0)")
#endif
        // Remove existing time observer before creating new player
        removeTimeObserver()
        playerItemObserver = nil
        timeControlStatusObserver = nil
        durationLoadTask?.cancel()
        durationLoadTask = nil
        if let observer = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfPlaybackObserver = nil
        }

        playbackDidReachEnd = false
        currentTime = 0.0
        currentURL = url
        pendingSeekTime = time
        
        // Set Now Playing info immediately when loading audio
#if DEBUG
        print("📂 [LOAD] Setting Now Playing info immediately")
#endif
        updateNowPlayingInfo(title: title, duration: duration, currentTime: time ?? 0.0)
        
        player = AVPlayer(url: url)
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.allowsExternalPlayback = true
        player?.volume = 1.0
        addPeriodicTimeObserver()
        observeTimeControlStatus()
        updateDuration()
        setupEndOfPlaybackObserver()

        if pendingSeekTime != nil, let item = player?.currentItem {
            playerItemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch status {
                    case .readyToPlay:
                        if let pendingSeekTime = self.pendingSeekTime {
                            self.seek(to: pendingSeekTime)
                            self.pendingSeekTime = nil
                        }
                        self.playerItemObserver = nil
                    case .failed:
                        self.pendingSeekTime = nil
                        self.playerItemObserver = nil
                    case .unknown:
                        break
                    @unknown default:
                        self.playerItemObserver = nil
                    }
                }
            }
        }
    }

    func play() {
#if DEBUG
        print("▶️ [PLAYER] play() called at \(Date())")
#endif
#if DEBUG
        print("▶️ [PLAYER] Current state - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil), timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1)")
#endif
        #if os(iOS)
#if DEBUG
        print("▶️ [PLAYER] Audio session active: \(isAudioSessionActive)")
#endif
        #endif
        AppLogger.playback.info("play() called - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil)")
        #if os(iOS)
        beginBackgroundTaskIfNeeded()
        #endif
#if DEBUG
        print("▶️ [PLAYER] Ensuring audio session active")
#endif
        ensureAudioSessionActive()
#if DEBUG
        print("▶️ [PLAYER] Ensuring now playing configured")
#endif
        ensureNowPlayingConfigured()
#if DEBUG
        print("▶️ [PLAYER] Calling playImmediately(atRate: \(playbackRate))")
#endif
        player?.playImmediately(atRate: playbackRate)
#if DEBUG
        print("▶️ [PLAYER] Updating playback state")
#endif
        updatePlaybackState()
        updatePlaybackRate()
        #if os(iOS)
        refreshNowPlayingInfo()
        #endif
        playbackDidReachEnd = false
#if DEBUG
        print("▶️ [PLAYER] play() completed at \(Date()) - isPlaying: \(self.isPlaying), timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1)")
#endif
        AppLogger.playback.info("play() completed - isPlaying: \(self.isPlaying)")
    }

    func pause() {
#if DEBUG
        print("⏸️ [PLAYER] pause() called at \(Date())")
#endif
#if DEBUG
        print("⏸️ [PLAYER] Current state - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil), timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1)")
#endif
        AppLogger.playback.info("pause() called - isPlaying: \(self.isPlaying)")
#if DEBUG
        print("⏸️ [PLAYER] Calling player.pause()")
#endif
        player?.pause()
        isPlaying = false
        #if os(iOS)
        endBackgroundTaskIfNeeded()
        #endif
#if DEBUG
        print("⏸️ [PLAYER] Updating playback state")
#endif
        updatePlaybackState()
        updatePlaybackRate()
        #if os(iOS)
        refreshNowPlayingInfo()
        #endif
#if DEBUG
        print("⏸️ [PLAYER] pause() completed at \(Date()) - isPlaying: \(self.isPlaying), timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1)")
#endif
        AppLogger.playback.info("pause() completed - isPlaying: \(self.isPlaying)")
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: preferredTimescale)
        player?.seek(to: cmTime)
        #if os(iOS)
        // Update NowPlayingInfo with new position
        refreshNowPlayingInfo(withCurrentTime: time)
        #endif
        playbackDidReachEnd = false
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: PlaybackDefaults.timeObserverInterval, preferredTimescale: preferredTimescale)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = seconds
                #if os(iOS)
                // Update now playing elapsed time
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                #endif
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func updateDuration() {
        durationLoadTask?.cancel()
        durationLoadTask = Task { @MainActor in
            guard let asset = player?.currentItem?.asset else { return }
            do {
                let duration = try await asset.load(.duration)
                guard !Task.isCancelled else { return }
                let seconds = duration.seconds
                if seconds.isFinite {
                    self.duration = seconds
                }
            } catch {
                AppLogger.playback.error("Failed to load duration: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // MARK: - Skip Controls
    
    func skipForward(_ seconds: Double? = nil) {
        guard duration > 0 else { return }
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipForwardSeconds
        let newTime = min(currentTime + skipSeconds, duration)
        seek(to: newTime)
    }
    
    func skipBackward(_ seconds: Double? = nil) {
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipBackwardSeconds
        let newTime = max(currentTime - skipSeconds, 0)
        seek(to: newTime)
    }
    
    // MARK: - Playback Speed
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        // Only set player rate when actively playing to avoid starting playback
        if rate > 0 && player?.timeControlStatus == .playing {
            player?.rate = rate
        }
        updatePlaybackRate()
        
        // Save to settings
        cachedPlaybackSettings.defaultPlaybackSpeed = rate
        cachedPlaybackSettings.save()
    }
    
    @MainActor
    private func updatePlaybackState(from player: AVPlayer? = nil) {
        let status = (player ?? self.player)?.timeControlStatus
        let newPlayingState = status == .playing
        if newPlayingState != isPlaying {
#if DEBUG
            print("🎯 [STATE] Playback state changed: \(isPlaying ? "playing" : "paused") -> \(newPlayingState ? "playing" : "paused") (timeControlStatus: \(status?.rawValue ?? -1)) at \(Date())")
#endif
        }
        isPlaying = newPlayingState
        #if os(iOS)
        if isPlaying {
            beginBackgroundTaskIfNeeded()
        } else {
            endBackgroundTaskIfNeeded()
        }
        #endif
    }

    private func observeTimeControlStatus() {
        timeControlStatusObserver = player?.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
#if DEBUG
            print("👁️ [OBSERVER] timeControlStatus changed to: \(player.timeControlStatus) at \(Date())")
#endif
            Task { @MainActor [weak self] in
                self?.updatePlaybackState(from: player)
            }
        }
    }

    private func setupEndOfPlaybackObserver() {
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.playbackDidReachEnd = true
                AppLogger.playback.info("Playback reached end of item")
            }
        }
    }

    // Singleton lifecycle persists for app duration; no deinit cleanup needed.
}
