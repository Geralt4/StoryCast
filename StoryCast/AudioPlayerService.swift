import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

#if os(iOS)
import MediaPlayer
import UIKit
#endif

@MainActor
class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()
    
    @Published var isPlaying = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var playbackRate: Float = 1.0
    @Published var playbackDidReachEnd = false
    
    private(set) var currentURL: URL?
    
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
    
    private let audioSessionManager = AudioSessionManager.shared
    private let remoteCommandHandler = RemoteCommandHandler.shared
    private let backgroundManager = PlaybackBackgroundManager.shared
    
    private init() {
        audioSessionManager.setup()
        remoteCommandHandler.setup()
        backgroundManager.setup()
        
        #if os(iOS)
        audioSessionManager.delegate = self
        remoteCommandHandler.delegate = self
        backgroundManager.delegate = self
        #endif
        
        observePlaybackSettingsChanges()
        playbackRate = cachedPlaybackSettings.defaultPlaybackSpeed
    }
    
    // MARK: - Audio Loading
    
    func loadAuthenticatedAudio(stream: AuthenticatedStream, title: String, duration: Double, seekTo time: Double? = nil) {
        loadAudioAsset(
            url: stream.url,
            title: title,
            duration: duration,
            seekTo: time,
            assetOptions: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers]
        )
    }
    
    func loadAudio(url: URL, title: String, duration: Double, seekTo time: Double? = nil) {
        loadAudioAsset(url: url, title: title, duration: duration, seekTo: time)
    }
    
    private var isLoadingAsset = false
    
    private func loadAudioAsset(
        url: URL,
        title: String,
        duration: Double,
        seekTo time: Double? = nil,
        assetOptions: [String: Any]? = nil
    ) {
        guard !isLoadingAsset else {
            AppLogger.playback.warning("Ignoring concurrent loadAudioAsset call")
            return
        }
        isLoadingAsset = true
        defer { isLoadingAsset = false }
        
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay:
                        if let pendingSeekTime = self.pendingSeekTime {
                            self.seek(to: pendingSeekTime)
                            self.pendingSeekTime = nil
                        }
                        self.playerItemObserver = nil
                    case .failed, .unknown:
                        self.pendingSeekTime = nil
                        self.playerItemObserver = nil
                    @unknown default:
                        self.playerItemObserver = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Playback Control
    
    func play() {
        AppLogger.playback.info("play() called - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil)")
        #if os(iOS)
        backgroundManager.isPlaying = true
        remoteCommandHandler.isPlaying = true
        #endif
        audioSessionManager.ensureActive()
        player?.playImmediately(atRate: playbackRate)
        updatePlaybackRate()
        playbackDidReachEnd = false
        AppLogger.playback.info("play() completed - isPlaying: \(self.isPlaying)")
    }
    
    func pause() {
        AppLogger.playback.info("pause() called - isPlaying: \(self.isPlaying)")
        player?.pause()
        isPlaying = false
        #if os(iOS)
        backgroundManager.isPlaying = false
        remoteCommandHandler.isPlaying = false
        #endif
        updatePlaybackRate()
        AppLogger.playback.info("pause() completed - isPlaying: \(self.isPlaying)")
    }
    
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }
    
    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else {
            AppLogger.playback.warning("Ignoring seek to invalid time: \(time)")
            return
        }
        PlaybackSessionManager.shared.markSeeking()
        let clampedTime = min(time, duration > 0 ? duration : time)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: preferredTimescale)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.currentTime = clampedTime
            }
        }
        #if os(iOS)
        remoteCommandHandler.updateElapsedTime(clampedTime)
        #endif
        playbackDidReachEnd = false
    }
    
    // MARK: - Skip Controls
    
    func skipForward(_ seconds: Double? = nil) {
        guard duration > 0, currentTime.isFinite else { return }
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipForwardSeconds
        seek(to: min(currentTime + skipSeconds, duration))
    }
    
    func skipBackward(_ seconds: Double? = nil) {
        guard currentTime.isFinite else { return }
        let skipSeconds = seconds ?? cachedPlaybackSettings.skipBackwardSeconds
        seek(to: max(currentTime - skipSeconds, 0))
    }
    
    // MARK: - Playback Speed
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if rate > 0 && player?.timeControlStatus == .playing {
            player?.rate = rate
        }
        updatePlaybackRate()
        cachedPlaybackSettings.defaultPlaybackSpeed = rate
        cachedPlaybackSettings.save()
    }
    
    // MARK: - Now Playing Info
    
    func updateNowPlayingInfo(title: String, duration: Double, currentTime: Double, artwork: UIImage? = nil) {
        #if os(iOS)
        remoteCommandHandler.updateNowPlayingInfo(title: title, duration: duration, currentTime: currentTime, artwork: artwork)
        #endif
    }
    
    func updateNowPlayingTitle(_ title: String) {
        updateNowPlayingInfo(title: title, duration: duration, currentTime: currentTime)
    }
    
    private func updatePlaybackRate() {
        #if os(iOS)
        remoteCommandHandler.updatePlaybackRate(rate: playbackRate, isPlaying: isPlaying)
        #endif
    }
    
    // MARK: - Private Helpers
    
    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: PlaybackDefaults.timeObserverInterval, preferredTimescale: preferredTimescale)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                #if os(iOS)
                self.remoteCommandHandler.updateElapsedTime(time.seconds)
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
                if seconds.isFinite { self.duration = seconds }
            } catch {
                AppLogger.playback.error("Failed to load duration: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    
    private func observeTimeControlStatus() {
        timeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.updatePlaybackState(from: player)
            }
        }
    }
    
    private func updatePlaybackState(from player: AVPlayer? = nil) {
        let status = (player ?? self.player)?.timeControlStatus
        isPlaying = status == .playing
        #if os(iOS)
        PlaybackBackgroundManager.shared.isPlaying = isPlaying
        remoteCommandHandler.isPlaying = isPlaying
        #endif
    }
    
    private func setupEndOfPlaybackObserver() {
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackDidReachEnd = true
                AppLogger.playback.info("Playback reached end of item")
            }
        }
    }
    
    private func observePlaybackSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settings = PlaybackSettings.load()
                let previousPlaybackRate = self.cachedPlaybackSettings.defaultPlaybackSpeed
                self.cachedPlaybackSettings = settings
                if settings.defaultPlaybackSpeed != previousPlaybackRate {
                    self.playbackRate = settings.defaultPlaybackSpeed
                    if self.isPlaying { self.player?.rate = self.playbackRate }
                    self.updatePlaybackRate()
                }
                #if os(iOS)
                self.remoteCommandHandler.skipForwardSeconds = settings.skipForwardSeconds
                self.remoteCommandHandler.skipBackwardSeconds = settings.skipBackwardSeconds
                self.remoteCommandHandler.updateSkipIntervals()
                #endif
            }
        }
    }
    
    // MARK: - Lifecycle Helpers
    
    private func ensureBackgroundPlayback() {
        #if os(iOS)
        guard isPlaying else {
            backgroundManager.isPlaying = false
            return
        }
        backgroundManager.isPlaying = true
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        #endif
    }
    
    private func ensureForegroundPlayback() {
        #if os(iOS)
        guard isPlaying else { return }
        audioSessionManager.ensureActive()
        updatePlaybackRate()
        #endif
    }
}

// MARK: - AudioSessionDelegate

#if os(iOS)
extension AudioPlayerService: AudioSessionDelegate {
    nonisolated func audioSessionInterruptionBegan() {
        Task { @MainActor in
            self.wasPlayingBeforeInterruption = self.isPlaying
            if self.isPlaying {
                self.player?.pause()
                self.updatePlaybackState()
                self.updatePlaybackRate()
                // Save position to prevent data loss if app terminates during interruption
                NotificationCenter.default.post(name: .init("StoryCast.SavePlaybackPosition"), object: nil)
                AppLogger.playback.info("Paused due to audio interruption")
            }
        }
    }
    
    nonisolated func audioSessionInterruptionEnded() {
        Task { @MainActor in
            if self.wasPlayingBeforeInterruption {
                await self.attemptPlaybackResumptionWithRetry()
            }
        }
    }

    @MainActor
    private func attemptPlaybackResumptionWithRetry() async {
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                self.play()
                return
            } catch {
                AppLogger.playback.warning("Playback resumption attempt \(attempt) failed: \(error.localizedDescription, privacy: .private)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                }
            }
        }
        AppLogger.playback.error("All playback resumption attempts failed — user may need to manually resume")
    }
    
    nonisolated func audioSessionRouteChanged(reason: AVAudioSession.RouteChangeReason) {
        if reason == .oldDeviceUnavailable {
            Task { @MainActor in self.pause() }
        }
    }
}
#endif

// MARK: - RemoteCommandDelegate

#if os(iOS)
extension AudioPlayerService: RemoteCommandDelegate {
    nonisolated func remoteCommandPlay() {
        Task { @MainActor in self.play() }
    }
    
    nonisolated func remoteCommandPause() {
        Task { @MainActor in self.pause() }
    }
    
    nonisolated func remoteCommandTogglePlayPause(isPlaying: Bool) {
        Task { @MainActor in
            if isPlaying { self.pause() } else { self.play() }
        }
    }
    
    nonisolated func remoteCommandSkipForward() {
        Task { @MainActor in self.skipForward() }
    }
    
    nonisolated func remoteCommandSkipBackward() {
        Task { @MainActor in self.skipBackward() }
    }
    
    nonisolated func remoteCommandSeek(to time: Double) {
        Task { @MainActor in self.seek(to: time) }
    }
}
#endif

// MARK: - PlaybackLifecycleDelegate

#if os(iOS)
extension AudioPlayerService: PlaybackLifecycleDelegate {
    nonisolated func playbackWillResignActive() {
        Task { @MainActor in self.ensureBackgroundPlayback() }
    }
    
    nonisolated func playbackDidEnterBackground() {
        Task { @MainActor in self.ensureBackgroundPlayback() }
    }
    
    nonisolated func playbackWillEnterForeground() {
        Task { @MainActor in self.ensureForegroundPlayback() }
    }
    
    nonisolated func playbackDidBecomeActive() {
        Task { @MainActor in self.ensureBackgroundPlayback() }
    }
    
    nonisolated func playbackProtectedDataWillBecomeUnavailable() {
        Task { @MainActor in self.ensureBackgroundPlayback() }
    }
    
    nonisolated func playbackProtectedDataDidBecomeAvailable() {
        Task { @MainActor in self.ensureForegroundPlayback() }
    }
}
#endif