import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

#if os(iOS)
import MediaPlayer
import UIKit
#endif

/// One file of the book in the player queue. The file's index and the queue
/// token travel with the item, so a callback can never pair one file's time with
/// another file's position in the book.
final class TrackPlayerItem: AVPlayerItem {
    let trackIndex: Int
    let token: Int

    init(asset: AVAsset, trackIndex: Int, token: Int) {
        self.trackIndex = trackIndex
        self.token = token
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil as [String]?)
    }
}

@MainActor
class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    /// Whether the user wants playback: true from `play()` until a pause, the end
    /// of the book, an interruption or a failure. It stays true while the player
    /// buffers at a file boundary or finishes a seek, so the UI, sleep timer and
    /// Now Playing don't flicker between files.
    @Published var isPlaying = false
    /// Whether audio is actually advancing (`timeControlStatus == .playing`).
    @Published private(set) var isAudioAdvancing = false
    /// Position in whole-book seconds, across all files of the book.
    @Published var currentTime: Double = 0.0
    /// Length of the whole book as laid out by the current source.
    @Published var duration: Double = 0.0
    @Published var playbackRate: Float = 1.0
    @Published var playbackDidReachEnd = false
    @Published private(set) var lastPlaybackError: String?
    /// Increases on every load and unload. Listeners use it to reset anything
    /// that assumes the playback position moved continuously.
    @Published private(set) var loadGeneration = 0

    private(set) var currentURL: URL?
    private(set) var currentBookID: UUID?
    private(set) var currentSource: PlaybackSource?

    private struct PendingSeek {
        let generation: Int
        let token: Int
        let trackIndex: Int
        var offset: Double
        let globalTime: Double
        var hasRetried = false
    }

    private var player: AVQueuePlayer?
    private var assets: [AVURLAsset] = []
    private var queueToken = 0
    private var queueRebuildCount = 0
    private var seekGeneration = 0
    private var pendingSeek: PendingSeek?
    private var isAudioSessionReadyForPlay = false
    private var needsRebuildOnPlay = false
    private var timeObserverToken: Any?
    private var cachedPlaybackSettings = PlaybackSettings.load()
    private var settingsObserver: Any?
    private var itemNotificationObservers: [Any] = []
    private var itemStatusObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var currentItemObserver: NSKeyValueObservation?
    private var wasPlayingBeforeInterruption = false
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var durationLoadTask: Task<Void, Never>?
    private var pendingPlayTask: Task<Void, Never>?
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
        observeItemNotifications()
        playbackRate = cachedPlaybackSettings.defaultPlaybackSpeed
    }

    // MARK: - Audio Loading

    func loadAuthenticatedAudio(stream: AuthenticatedStream, title: String, duration: Double, seekTo time: Double? = nil) {
        load(
            source: .singleFile(url: stream.url, duration: duration, bookID: nil, httpHeaders: stream.headers),
            title: title,
            seekTo: time
        )
    }

    func loadAudio(url: URL, title: String, duration: Double, seekTo time: Double? = nil) {
        load(source: .singleFile(url: url, duration: duration, bookID: nil), title: title, seekTo: time)
    }

    private var isLoadingAsset = false

    /// Loads a book made of one or more files and positions it at `time`
    /// (whole-book seconds). Playback does not start until `play()`.
    func load(source: PlaybackSource, title: String, seekTo time: Double? = nil) {
        guard !isLoadingAsset else {
            AppLogger.playback.warning("Ignoring concurrent load call")
            return
        }
        isLoadingAsset = true
        defer { isLoadingAsset = false }

        tearDownPlayer()

        var source = source
        if let time, time.isFinite {
            source = source.withDurationHint(atLeast: time)
        }
        currentSource = source
        currentURL = source.identityURL
        currentBookID = source.bookID
        loadGeneration += 1
        lastPlaybackError = nil
        needsRebuildOnPlay = false
        playbackDidReachEnd = false
        // Publish the whole-book length now, so nothing clamps a resume position
        // against the previous book's duration while assets load.
        duration = source.timeline.duration
        let startTime = source.timeline.clamp(time ?? 0)
        currentTime = startTime
        updateNowPlayingInfo(title: title, duration: duration, currentTime: startTime)

        let options: [String: Any]? = source.httpHeaders.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": source.httpHeaders]
        assets = source.trackURLs.map { AVURLAsset(url: $0, options: options) }

        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = source.isLocal
        player.volume = 1.0
        player.defaultRate = playbackRate
        self.player = player
        addPeriodicTimeObserver()
        observeTimeControlStatus()
        observeCurrentItem()
        if source.durationIsHint {
            refineHintedDuration()
        }
        rebuildQueue(at: startTime)
    }

    /// Stops playback and releases the current book, e.g. before its files are
    /// deleted.
    func unload() {
        tearDownPlayer()
        currentSource = nil
        currentURL = nil
        currentBookID = nil
        currentTime = 0
        duration = 0
        playbackDidReachEnd = false
        lastPlaybackError = nil
        needsRebuildOnPlay = false
        loadGeneration += 1
        updatePlaybackRate()
    }

    func clearPlaybackError() {
        lastPlaybackError = nil
    }

    // MARK: - Playback Control

    func play() {
        AppLogger.playback.info("play() called - isPlaying: \(self.isPlaying), hasPlayer: \(self.player != nil)")
        guard let player else { return }
        setPlayIntent(true)
        if needsRebuildOnPlay || (player.currentItem == nil && currentSource != nil) {
            // After a failure or the end of the book the queue is empty; start
            // again from the current position.
            needsRebuildOnPlay = false
            lastPlaybackError = nil
            rebuildQueue(at: currentTime)
        }
        pendingPlayTask?.cancel()
        pendingPlayTask = Task { @MainActor in
            do {
                try await audioSessionManager.ensureActive()
                guard !Task.isCancelled, self.isPlaying else { return }
                self.isAudioSessionReadyForPlay = true
                self.resumePlaybackIfReady()
            } catch {
                AppLogger.playback.error("Playback blocked: audio session activation failed: \(error.localizedDescription, privacy: .private)")
                self.setPlayIntent(false)
                self.updatePlaybackRate()
            }
        }
    }

    /// Starts audio once playback is wanted, the audio session is active and no
    /// seek is still in flight.
    private func resumePlaybackIfReady() {
        guard isPlaying, isAudioSessionReadyForPlay, pendingSeek == nil,
              let player, player.currentItem != nil else { return }
        player.playImmediately(atRate: playbackRate)
        playbackDidReachEnd = false
        updatePlaybackRate()
        AppLogger.playback.info("play() completed - isPlaying: \(self.isPlaying)")
    }

    func pause() {
        AppLogger.playback.info("pause() called - isPlaying: \(self.isPlaying)")
        pendingPlayTask?.cancel()
        pendingPlayTask = nil
        isAudioSessionReadyForPlay = false
        player?.pause()
        setPlayIntent(false)
        updatePlaybackRate()
        AppLogger.playback.info("pause() completed - isPlaying: \(self.isPlaying)")
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Moves to `time` in whole-book seconds, switching files when needed.
    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else {
            AppLogger.playback.warning("Ignoring seek to invalid time: \(time)")
            return
        }
        guard let player, let source = currentSource else { return }
        PlaybackSessionManager.shared.markSeeking()

        let location = source.timeline.location(for: source.timeline.clamp(time))
        let target = source.timeline.globalTime(segmentIndex: location.segmentIndex, offset: location.offset)
        playbackDidReachEnd = false
        publishTime(target)

        let current = player.currentItem as? TrackPlayerItem
        if let current, current.token == queueToken, current.trackIndex == location.segmentIndex {
            startSeek(on: current, offset: location.offset, globalTime: target)
        } else if let current, current.token == queueToken,
                  let queued = player.items().dropFirst().first as? TrackPlayerItem,
                  queued.trackIndex == location.segmentIndex {
            // The target file is already preloaded: advance to it instead of
            // rebuilding the queue.
            seekGeneration += 1
            pendingSeek = PendingSeek(
                generation: seekGeneration,
                token: queued.token,
                trackIndex: queued.trackIndex,
                offset: location.offset,
                globalTime: target
            )
            player.pause()
            player.advanceToNextItem()
            applyPendingSeekIfReady(on: queued)
        } else {
            rebuildQueue(at: target)
        }
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
        player?.defaultRate = rate
        if rate > 0, let player, player.rate != 0 {
            player.rate = rate
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

    // MARK: - Queue

    private func tearDownPlayer() {
        removeTimeObserver()
        timeControlStatusObserver = nil
        currentItemObserver = nil
        itemStatusObservers.removeAll()
        durationLoadTask?.cancel()
        durationLoadTask = nil
        pendingPlayTask?.cancel()
        pendingPlayTask = nil
        isAudioSessionReadyForPlay = false
        pendingSeek = nil
        queueToken += 1
        player?.pause()
        player?.removeAllItems()
        player = nil
        assets = []
        isAudioAdvancing = false
        setPlayIntent(false)
    }

    /// Replaces the queue with the file containing `time` (plus the next file)
    /// and positions it there once it is ready.
    private func rebuildQueue(at time: Double) {
        guard let player, let source = currentSource else { return }
        queueToken += 1
        queueRebuildCount += 1
        let token = queueToken
        itemStatusObservers.removeAll()

        let location = source.timeline.location(for: time)
        let target = source.timeline.globalTime(segmentIndex: location.segmentIndex, offset: location.offset)
        // Record the seek before pausing, so the status change it causes isn't
        // mistaken for the user or the system stopping playback.
        seekGeneration += 1
        pendingSeek = PendingSeek(
            generation: seekGeneration,
            token: token,
            trackIndex: location.segmentIndex,
            offset: location.offset,
            globalTime: target
        )
        player.pause()
        player.removeAllItems()

        let first = makeItem(trackIndex: location.segmentIndex, token: token)
        player.insert(first, after: nil)
        appendNextItemIfNeeded(after: first)
        publishTime(target)
        applyPendingSeekIfReady(on: first)
    }

    private func makeItem(trackIndex: Int, token: Int) -> TrackPlayerItem {
        let item = TrackPlayerItem(asset: assets[trackIndex], trackIndex: trackIndex, token: token)
        observeStatus(of: item)
        return item
    }

    /// Keeps at most the current file and the next one enqueued, as the
    /// AVQueuePlayer documentation recommends: every enqueued item starts loading.
    private func appendNextItemIfNeeded(after item: TrackPlayerItem) {
        guard let player, let source = currentSource,
              player.items().last === item,
              let next = source.timeline.nextPlayableSegment(after: item.trackIndex) else { return }
        let nextItem = makeItem(trackIndex: next, token: item.token)
        if player.canInsert(nextItem, after: item) {
            player.insert(nextItem, after: item)
        } else {
            itemStatusObservers[ObjectIdentifier(nextItem)] = nil
        }
    }

    private func startSeek(on item: TrackPlayerItem, offset: Double, globalTime: Double) {
        seekGeneration += 1
        pendingSeek = PendingSeek(
            generation: seekGeneration,
            token: item.token,
            trackIndex: item.trackIndex,
            offset: offset,
            globalTime: globalTime
        )
        applyPendingSeekIfReady(on: item)
    }

    /// Seeks right away when the item is ready; otherwise its status observer
    /// performs the seek once it becomes ready.
    private func applyPendingSeekIfReady(on item: TrackPlayerItem) {
        guard item.status == .readyToPlay else { return }
        performPendingSeek(on: item)
    }

    private func performPendingSeek(on item: TrackPlayerItem) {
        guard let pending = pendingSeek, pending.token == item.token,
              pending.trackIndex == item.trackIndex else { return }
        let generation = pending.generation
        let target = CMTime(seconds: pending.offset, preferredTimescale: preferredTimescale)
        item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] finished in
            Task { @MainActor [weak self] in
                self?.completeSeek(generation: generation, finished: finished, item: item)
            }
        }
    }

    private func completeSeek(generation: Int, finished: Bool, item: TrackPlayerItem) {
        guard var pending = pendingSeek, pending.generation == generation else { return }

        // A seek past what the file can reach (the server's duration can differ
        // slightly from the decoded one) is cancelled; retry just before the end.
        if !finished, !pending.hasRetried, item.token == queueToken, item.status == .readyToPlay {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 {
                pending.offset = max(0, min(pending.offset, itemDuration - 0.5))
                pending.hasRetried = true
                pendingSeek = pending
                performPendingSeek(on: item)
                return
            }
        }

        pendingSeek = nil
        if let source = currentSource, item.token == queueToken {
            let landed = item.currentTime()
            let global = landed.isNumeric
                ? source.timeline.globalTime(segmentIndex: item.trackIndex, offset: landed.seconds)
                : pending.globalTime
            publishTime(global)
        }
        resumePlaybackIfReady()
    }

    private func publishTime(_ time: Double) {
        currentTime = time
        #if os(iOS)
        remoteCommandHandler.updateElapsedTime(time)
        #endif
    }

    private func handleCurrentItemChanged() {
        guard let player, let item = player.currentItem as? TrackPlayerItem,
              item.token == queueToken else { return }
        appendNextItemIfNeeded(after: item)
        let queued = Set(player.items().map(ObjectIdentifier.init))
        itemStatusObservers = itemStatusObservers.filter { queued.contains($0.key) }
        if isPlaying, pendingSeek == nil, player.rate != 0, player.rate != playbackRate {
            player.rate = playbackRate
        }
    }

    private func handleItemReachedEnd(_ item: TrackPlayerItem) {
        guard item.token == queueToken, let player, let source = currentSource else { return }
        let lastPlayable = source.timeline.segments.indices.last { source.timeline.segments[$0].duration > 0 }
        if item.trackIndex == lastPlayable {
            publishTime(source.timeline.duration)
            isAudioSessionReadyForPlay = false
            setPlayIntent(false)
            updatePlaybackRate()
            playbackDidReachEnd = true
            AppLogger.playback.info("Playback reached end of book")
            return
        }

        guard let next = source.timeline.nextPlayableSegment(after: item.trackIndex) else { return }
        let nextIsQueued = player.items().contains {
            ($0 as? TrackPlayerItem)?.trackIndex == next && ($0 as? TrackPlayerItem)?.token == item.token
        }
        guard !nextIsQueued else { return }
        // The next file wasn't queued (it failed while preloading): try it again.
        AppLogger.playback.info("Next file missing from queue at end of file \(item.trackIndex); rebuilding")
        let shouldContinue = isPlaying
        rebuildQueue(at: source.timeline.segments[next].startOffset)
        if shouldContinue {
            setPlayIntent(true)
        }
    }

    private func handleItemFailure(_ item: TrackPlayerItem, message: String?) {
        guard item.token == queueToken, let player else { return }
        AppLogger.playback.error("Playback of file \(item.trackIndex) failed: \(message ?? "unknown error", privacy: .private)")
        guard item === player.currentItem else {
            // A preloading file failed; drop it and retry it when the current file ends.
            itemStatusObservers[ObjectIdentifier(item)] = nil
            player.remove(item)
            return
        }
        let position = currentTime
        pendingSeek = nil
        pendingPlayTask?.cancel()
        pendingPlayTask = nil
        isAudioSessionReadyForPlay = false
        player.pause()
        player.removeAllItems()
        itemStatusObservers.removeAll()
        needsRebuildOnPlay = true
        publishTime(position)
        setPlayIntent(false)
        updatePlaybackRate()
        lastPlaybackError = message ?? "This part of the book couldn't be played."
    }

    // MARK: - Private Helpers

    private func setPlayIntent(_ playing: Bool) {
        if isPlaying != playing {
            isPlaying = playing
        }
        #if os(iOS)
        backgroundManager.isPlaying = playing
        remoteCommandHandler.isPlaying = playing
        #endif
    }

    private func addPeriodicTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: PlaybackDefaults.timeObserverInterval, preferredTimescale: preferredTimescale)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishPlaybackTime()
            }
        }
    }

    /// Reads the time from the current item itself, so the file index and the
    /// time always belong to the same file.
    private func publishPlaybackTime() {
        guard pendingSeek == nil, let player, let source = currentSource,
              let item = player.currentItem as? TrackPlayerItem,
              item.token == queueToken else { return }
        let time = item.currentTime()
        guard time.isNumeric else { return }
        publishTime(source.timeline.globalTime(segmentIndex: item.trackIndex, offset: time.seconds))
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    /// For a single file whose length was only a guess, replaces the guess with
    /// the length decoded from the file.
    private func refineHintedDuration() {
        guard let asset = assets.first else { return }
        let generation = loadGeneration
        durationLoadTask = Task { @MainActor in
            do {
                let loaded = try await asset.load(.duration)
                guard !Task.isCancelled, generation == self.loadGeneration,
                      let source = self.currentSource else { return }
                let refined = source.withMeasuredDuration(loaded.seconds)
                guard refined != source else { return }
                self.currentSource = refined
                self.duration = refined.timeline.duration
                if self.currentTime > self.duration {
                    self.publishTime(self.duration)
                }
            } catch {
                AppLogger.playback.error("Failed to load duration: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func observeTimeControlStatus() {
        timeControlStatusObserver = player?.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.updatePlaybackState(from: player)
            }
        }
    }

    private func observeCurrentItem() {
        currentItemObserver = player?.observe(\.currentItem, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemChanged()
            }
        }
    }

    private func observeStatus(of item: TrackPlayerItem) {
        itemStatusObservers[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.performPendingSeek(on: item)
                case .failed:
                    self.handleItemFailure(item, message: item.error?.localizedDescription)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func updatePlaybackState(from observed: AVPlayer) {
        guard observed === player else { return }
        let status = observed.timeControlStatus
        isAudioAdvancing = status == .playing
        switch status {
        case .playing:
            if !isPlaying {
                setPlayIntent(true)
            }
        case .paused:
            // Pauses made for a seek or queue rebuild happen with a seek pending.
            // Any other pause after playback started (the queue ran out, the
            // system stopped the player) ends the play intent.
            if isPlaying, pendingSeek == nil, isAudioSessionReadyForPlay, observed.rate == 0 {
                isAudioSessionReadyForPlay = false
                setPlayIntent(false)
                updatePlaybackRate()
            }
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

    private func observeItemNotifications() {
        let center = NotificationCenter.default
        let didPlayToEnd = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? TrackPlayerItem else { return }
            MainActor.assumeIsolated {
                self?.handleItemReachedEnd(item)
            }
        }
        let failedToPlayToEnd = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? TrackPlayerItem else { return }
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription
            MainActor.assumeIsolated {
                self?.handleItemFailure(item, message: message)
            }
        }
        itemNotificationObservers = [didPlayToEnd, failedToPlayToEnd]
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
                    self.player?.defaultRate = self.playbackRate
                    if let player = self.player, player.rate != 0 { player.rate = self.playbackRate }
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
        Task { @MainActor in
            try? await audioSessionManager.ensureActive()
        }
        updatePlaybackRate()
        #endif
    }

    private func ensureForegroundPlayback() {
        #if os(iOS)
        guard isPlaying else { return }
        Task { @MainActor in
            try? await audioSessionManager.ensureActive()
        }
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
                self.pendingPlayTask?.cancel()
                self.pendingPlayTask = nil
                self.isAudioSessionReadyForPlay = false
                self.player?.pause()
                self.setPlayIntent(false)
                self.updatePlaybackRate()
                // Save position to prevent data loss if app terminates during interruption
                NotificationCenter.default.post(name: .savePlaybackPosition, object: nil)
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
        do {
            try await audioSessionManager.ensureActive()
            self.play()
        } catch {
            AppLogger.playback.error("Playback resumption failed — user may need to manually resume: \(error.localizedDescription, privacy: .private)")
        }
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
            self.togglePlayPause()
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

#if DEBUG
extension AudioPlayerService {
    var debugQueuedTrackIndices: [Int] {
        player?.items().compactMap { ($0 as? TrackPlayerItem)?.trackIndex } ?? []
    }
    var debugCurrentTrackIndex: Int? { (player?.currentItem as? TrackPlayerItem)?.trackIndex }
    var debugCurrentItem: AVPlayerItem? { player?.currentItem }
    var debugQueueRebuildCount: Int { queueRebuildCount }
    var debugIsSeekPending: Bool { pendingSeek != nil }
    var debugDefaultRate: Float? { player?.defaultRate }

    func debugPublishPlaybackTime() { publishPlaybackTime() }

    func debugHandleItemReachedEnd(_ item: AVPlayerItem?) {
        guard let item = item as? TrackPlayerItem else { return }
        handleItemReachedEnd(item)
    }

    func debugSimulateCurrentItemFailure(message: String) {
        guard let item = player?.currentItem as? TrackPlayerItem else { return }
        handleItemFailure(item, message: message)
    }
}
#endif
