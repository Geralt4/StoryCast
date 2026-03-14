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

/// Manages audio playback using AVPlayer for audiobook content.
///
/// `AudioPlayerService` is the central coordinator for all audio playback operations:
/// - Loads audio files from URLs
/// - Controls playback (play, pause, seek, toggle)
/// - Tracks progress and duration
/// - Adjusts playback speed (0.5x - 3.0x)
/// - Handles skip forward/backward commands
/// - Integrates with lock screen and Control Center
/// - Supports background playback
///
/// ## Architecture
///
/// Uses three manager singletons for separation of concerns:
/// - `AudioSessionManager`: Audio session configuration and interruptions
/// - `RemoteCommandHandler`: Lock screen controls and Now Playing info
/// - `PlaybackBackgroundManager`: Background task and lifecycle events
///
/// ## Usage
///
/// ```swift
/// let player = AudioPlayerService.shared
/// player.loadAudio(url: audioURL, title: "Book Title", duration: 3600)
/// player.play()
/// player.skipForward(30)
/// player.setPlaybackRate(1.5)
/// ```
///
/// ## Thread Safety
///
/// All methods run on `@MainActor`. The singleton persists for the app lifetime.
@MainActor
class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    /// Whether audio is currently playing.
    ///
    /// Updated automatically when playback state changes.
    /// Observed by UI to update play/pause buttons.
    @Published var isPlaying = false

    /// Current playback position in seconds.
    ///
    /// Updated periodically via AVPlayer time observer.
    /// Used by progress slider and time labels.
    @Published var currentTime: Double = 0.0

    /// Total audio duration in seconds.
    ///
    /// Loaded asynchronously when audio file is opened.
    /// May be 0.0 initially until duration is available.
    @Published var duration: Double = 0.0

    /// Playback speed multiplier.
    ///
    /// Range: 0.5 (half speed) to 3.0 (triple speed).
    /// Default: 1.0 (normal speed).
    /// Persists across app launches via PlaybackSettings.
    @Published var playbackRate: Float = 1.0

    /// Whether playback has reached the end of the audio file.
    ///
    /// Set to `true` when AVPlayerItemDidPlayToEndTime notification fires.
    /// Reset to `false` when loading new audio or seeking.
    @Published var playbackDidReachEnd = false
    
    /// The URL of the currently loaded audio file.
    private(set) var currentURL: URL?

    // MARK: - Private Properties
    
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var cachedPlaybackSettings = PlaybackSettings.load()
    private var settingsObserver: Any?
    private var pendingSeekTime: Double?
    private var playerItemObserver: NSKeyValueObservation?
    private var wasPlayingBeforeInterruption = false
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var durationLoadTask: Task<Void, Never>?
    private var endOfPlaybackObserver: Any?
    private let preferredTimescale: CMTimeScale = 600
    
    // MARK: - Manager Dependencies
    
    private let audioSessionManager = AudioSessionManager.shared
    private let remoteCommandHandler = RemoteCommandHandler.shared
    private let backgroundManager = PlaybackBackgroundManager.shared
    
    #if os(iOS)
    private var isAudioSessionActive = false
    #endif

    private init() {
        // Configure managers
        audioSessionManager.setup()
        remoteCommandHandler.setup()
        backgroundManager.setup()
        
        // Wire up manager callbacks - CRITICAL: Use [weak self] to prevent retain cycles
        wireUpAudioSessionCallbacks()
        wireUpRemoteCommandCallbacks()
        wireUpBackgroundCallbacks()
        
        // Observe playback settings
        observePlaybackSettingsChanges()
        playbackRate = cachedPlaybackSettings.defaultPlaybackSpeed
    }
    
    // MARK: - Manager Callbacks
    
    /// Wires up audio session interruption and route change callbacks.
    /// Uses weak self to prevent retain cycles with NotificationCenter observers.
    private func wireUpAudioSessionCallbacks() {
        audioSessionManager.onInterruptionBegan = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAudioInterruptionBegan()
            }
        }
        
        audioSessionManager.onInterruptionEnded = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAudioInterruptionEnded()
            }
        }
        
        audioSessionManager.onRouteChange = { [weak self] (reason: AVAudioSession.RouteChangeReason) in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleRouteChange(reason: reason)
            }
        }
    }
    
    /// Wires up remote command center callbacks for lock screen controls.
    /// Uses weak self to prevent retain cycles with MPRemoteCommandCenter.
    private func wireUpRemoteCommandCallbacks() {
        remoteCommandHandler.onPlay = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.play()
            }
        }
        
        remoteCommandHandler.onPause = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.pause()
            }
        }
        
        remoteCommandHandler.onTogglePlayPause = { [weak self] (isPlaying: Bool) in
            guard let self = self else { return }
            Task { @MainActor in
                if isPlaying {
                    self.pause()
                } else {
                    self.play()
                }
            }
        }
        
        remoteCommandHandler.onSkipForward = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.skipForward()
            }
        }
        
        remoteCommandHandler.onSkipBackward = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.skipBackward()
            }
        }
        
        remoteCommandHandler.onSeek = { [weak self] (time: Double) in
            guard let self = self else { return }
            Task { @MainActor in
                self.seek(to: time)
            }
        }
    }
    
    /// Wires up background task and lifecycle callbacks.
    /// Uses weak self to prevent retain cycles with UIApplication observers.
    private func wireUpBackgroundCallbacks() {
        backgroundManager.onWillResignActive = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAppWillResignActive()
            }
        }
        
        backgroundManager.onDidEnterBackground = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAppDidEnterBackground()
            }
        }
        
        backgroundManager.onWillEnterForeground = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAppWillEnterForeground()
            }
        }
        
        backgroundManager.onDidBecomeActive = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleAppDidBecomeActive()
            }
        }
        
        backgroundManager.onProtectedDataWillBecomeUnavailable = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleProtectedDataWillBecomeUnavailable()
            }
        }
        
        backgroundManager.onProtectedDataDidBecomeAvailable = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleProtectedDataDidBecomeAvailable()
            }
        }
    }

    func handleAppDidEnterBackground() {
        #if os(iOS)
        guard isPlaying else {
            backgroundManager.isPlaying = false
            return
        }
        backgroundManager.isPlaying = true
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        refreshNowPlayingInfo()
        #endif
    }

    func handleAppDidBecomeActive() {
        #if os(iOS)
        guard isPlaying else {
            backgroundManager.isPlaying = false
            return
        }
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        refreshNowPlayingInfo()
        #endif
    }
    
    // MARK: - Audio Session Interruption Handlers
    
    /// Handles audio interruption began event (phone calls, Siri, etc.)
    private func handleAudioInterruptionBegan() {
        #if os(iOS)
        wasPlayingBeforeInterruption = isPlaying
        if isPlaying {
            player?.pause()
            updatePlaybackState()
            updatePlaybackRate()
            isAudioSessionActive = false
            AppLogger.playback.info("Paused due to audio interruption (keeping background task)")
        }
        #endif
    }
    
    /// Handles audio interruption ended event
    private func handleAudioInterruptionEnded() {
        #if os(iOS)
        if wasPlayingBeforeInterruption {
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                isAudioSessionActive = true
                play()
            } catch {
                AppLogger.playback.error("Failed to reactivate audio session after interruption: \(error.localizedDescription, privacy: .private)")
            }
        }
        #endif
    }
    
    /// Handles audio route change events (headphones disconnect, etc.)
    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        #if os(iOS)
        if reason == .oldDeviceUnavailable {
            pause()
        }
        #endif
    }

    func handleAppWillResignActive() {
        #if os(iOS)
        guard isPlaying else { return }
        audioSessionManager.ensureActive()
        backgroundManager.isPlaying = true
        updatePlaybackRate()
        #endif
    }

    func handleAppWillEnterForeground() {
        #if os(iOS)
        guard isPlaying else { return }
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        #endif
    }

    func handleProtectedDataWillBecomeUnavailable() {
        #if os(iOS)
        guard isPlaying else { return }
        audioSessionManager.ensureActive()
        backgroundManager.isPlaying = true
        updatePlaybackRate()
        #endif
    }

    func handleProtectedDataDidBecomeAvailable() {
        #if os(iOS)
        guard isPlaying else { return }
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        #endif
    }

    private func observePlaybackSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let settings = PlaybackSettings.load()
                let previousPlaybackRate = self.cachedPlaybackSettings.defaultPlaybackSpeed
                self.cachedPlaybackSettings = settings
                if settings.defaultPlaybackSpeed != previousPlaybackRate {
                    self.playbackRate = settings.defaultPlaybackSpeed
                    if self.isPlaying {
                        self.player?.rate = self.playbackRate
                    }
                    self.updatePlaybackRate()
                }
                self.remoteCommandHandler.skipForwardSeconds = settings.skipForwardSeconds
                self.remoteCommandHandler.skipBackwardSeconds = settings.skipBackwardSeconds
                self.remoteCommandHandler.updateSkipIntervals()
            }
        }
    }

    func updateNowPlayingInfo(title: String, duration: Double, currentTime: Double, artwork: UIImage? = nil) {
        #if os(iOS)
        remoteCommandHandler.updateNowPlayingInfo(
            title: title,
            duration: duration,
            currentTime: currentTime,
            artwork: artwork
        )
        #endif
    }
    
    func updateNowPlayingTitle(_ title: String) {
        #if os(iOS)
        remoteCommandHandler.updateNowPlayingInfo(
            title: title,
            duration: duration,
            currentTime: currentTime,
            artwork: nil
        )
        #endif
    }
    
    #if os(iOS)
    private func refreshNowPlayingInfo(withCurrentTime currentTime: Double? = nil) {
        remoteCommandHandler.updateNowPlayingInfo(
            title: "",
            duration: duration,
            currentTime: currentTime ?? self.currentTime,
            artwork: nil
        )
    }
    #endif

    private func updatePlaybackRate() {
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    func loadAuthenticatedAudio(stream: AuthenticatedStream, title: String, duration: Double, seekTo time: Double? = nil) {
        loadAudioAsset(
            url: stream.url,
            title: title,
            duration: duration,
            seekTo: time,
            assetOptions: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers]
        )
    }

    /// Loads audio from a URL and prepares for playback.
    ///
    /// This method:
    /// 1. Removes existing time observers and cleans up AVPlayer
    /// 2. Creates a new AVPlayer instance with the provided URL
    /// 3. Sets up periodic time observer for progress tracking
    /// 4. Asynchronously loads the audio duration
    /// 5. Sets up end-of-playback notification observer
    /// 6. Updates Now Playing info with the provided metadata
    /// 7. Performs initial seek if `seekTo` is provided
    ///
    /// - Parameters:
    ///   - url: The file URL of the audio to load. Must be a valid audio file.
    ///   - title: The title displayed in Now Playing (lock screen, Control Center).
    ///   - duration: Expected duration in seconds. Updated when actual duration loads.
    ///   - seekTo: Optional initial playback position in seconds. If nil, starts at 0.
    ///
    /// - Note: Call this before `play()` to prepare the player.
    /// - Important: This resets `playbackDidReachEnd` to `false`.
    func loadAudio(url: URL, title: String, duration: Double, seekTo time: Double? = nil) {
        loadAudioAsset(url: url, title: title, duration: duration, seekTo: time)
    }

    private func loadAudioAsset(
        url: URL,
        title: String,
        duration: Double,
        seekTo time: Double? = nil,
        assetOptions: [String: Any]? = nil
    ) {
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
        updateNowPlayingInfo(title: title, duration: duration, currentTime: time ?? 0.0)

        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
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

    /// Starts or resumes audio playback.
    ///
    /// This method:
    /// 1. Activates the audio session (ensures background playback is enabled)
    /// 2. Calls `playImmediately(atRate:)` on the AVPlayer
    /// 3. Updates internal playing state
    /// 4. Refreshes Now Playing info with current metadata
    /// 5. Registers background task if needed
    ///
    /// - Note: If no audio is loaded, this has no effect.
    /// - Important: This resets `playbackDidReachEnd` to `false`.
    func play() {
        #if os(iOS)
        #endif
        AppLogger.playback.info("play() called - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil)")
        #if os(iOS)
        backgroundManager.isPlaying = true
        #endif
        audioSessionManager.ensureActive()
        player?.playImmediately(atRate: playbackRate)
        updatePlaybackState()
        updatePlaybackRate()
        #if os(iOS)
        refreshNowPlayingInfo()
        #endif
        playbackDidReachEnd = false
        AppLogger.playback.info("play() completed - isPlaying: \(self.isPlaying)")
    }

    /// Pauses audio playback.
    ///
    /// This method:
    /// 1. Calls `pause()` on the AVPlayer
    /// 2. Updates internal playing state
    /// 3. Ends background task if running
    /// 4. Refreshes Now Playing info (shows paused state)
    ///
    /// - Note: Safe to call even if already paused.
    func pause() {
        AppLogger.playback.info("pause() called - isPlaying: \(self.isPlaying)")
        player?.pause()
        isPlaying = false
        #if os(iOS)
        backgroundManager.isPlaying = false
        remoteCommandHandler.isPlaying = false
        #endif
        updatePlaybackState()
        updatePlaybackRate()
        #if os(iOS)
        refreshNowPlayingInfo()
        #endif
        AppLogger.playback.info("pause() completed - isPlaying: \(self.isPlaying)")
    }

    /// Seeks to a specific playback position.
    ///
    /// Uses AVPlayer's seek(to:) for accurate positioning.
    /// Updates Now Playing elapsed time immediately.
    ///
    /// - Parameter time: The position in seconds to seek to.
    ///                  Clamped to valid range (0 to duration).
    ///
    /// - Note: This resets `playbackDidReachEnd` to `false`.
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

    /// Toggles between play and pause states.
    ///
    /// Convenience method that calls `play()` if paused,
    /// or `pause()` if playing.
    ///
    /// - Note: Equivalent to pressing the play/pause button on lock screen.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // MARK: - Skip Controls
    
    /// Skips forward by the specified seconds.
    ///
    /// If no seconds specified, uses the user's preferred skip interval
    /// from PlaybackSettings (default: 30 seconds).
    ///
    /// - Parameter seconds: Optional skip duration in seconds.
    ///                      If nil, uses `skipForwardSeconds` from settings.
    ///
    /// - Note: Clamps to duration (won't skip past end).
    func skipForward(_ seconds: Double? = nil) {
        guard duration > 0 else { return }
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipForwardSeconds
        let newTime = min(currentTime + skipSeconds, duration)
        seek(to: newTime)
    }
    
    /// Skips backward by the specified seconds.
    ///
    /// If no seconds specified, uses the user's preferred skip interval
    /// from PlaybackSettings (default: 15 seconds).
    ///
    /// - Parameter seconds: Optional skip duration in seconds.
    ///                      If nil, uses `skipBackwardSeconds` from settings.
    ///
    /// - Note: Clamps to 0 (won't skip before start).
    func skipBackward(_ seconds: Double? = nil) {
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipBackwardSeconds
        let newTime = max(currentTime - skipSeconds, 0)
        seek(to: newTime)
    }
    
    // MARK: - Playback Speed
    
    /// Sets the playback speed multiplier.
    ///
    /// Valid range: 0.5 (half speed) to 3.0 (triple speed).
    /// Common values: 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
    ///
    /// This method:
    /// 1. Updates the `playbackRate` published property
    /// 2. Applies the rate to AVPlayer if currently playing
    /// 3. Updates Now Playing playback rate info
    /// 4. Persists the setting to PlaybackSettings
    ///
    /// - Parameter rate: The playback speed multiplier.
    ///                   Must be > 0. Typical range: 0.5 - 3.0.
    ///
    /// - Note: Setting rate to 0 pauses playback.
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
        }
        isPlaying = newPlayingState
        #if os(iOS)
        PlaybackBackgroundManager.shared.isPlaying = newPlayingState
        remoteCommandHandler.isPlaying = newPlayingState
        #endif
    }

    private func observeTimeControlStatus() {
        timeControlStatusObserver = player?.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
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
