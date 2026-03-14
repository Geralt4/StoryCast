import Foundation
import os

#if os(iOS)
import UIKit
import MediaPlayer
#endif

/// Handles Now Playing info and remote command center for lock screen controls.
///
/// `RemoteCommandHandler` manages:
/// - Now Playing metadata (title, duration, artwork, playback state)
/// - Remote command center (play, pause, skip, seek)
/// - Lock screen and Control Center integration
///
/// ## Remote Commands Supported
///
/// - Play/Pause/Toggle
/// - Skip forward/backward (configurable intervals)
/// - Seek to position
///
/// ## Usage
///
/// ```swift
/// let handler = RemoteCommandHandler.shared
/// handler.setup()
/// handler.updateNowPlayingInfo(
///     title: "Book Title",
///     duration: 3600,
///     currentTime: 120,
///     artwork: image
/// )
/// ```
@MainActor
final class RemoteCommandHandler {
    static let shared = RemoteCommandHandler()
    
    /// Whether Now Playing has been configured.
    private var isConfigured = false
    
    /// Current Now Playing metadata.
    private var nowPlayingTitle: String = ""
    private var nowPlayingDuration: Double = 0.0
    private var nowPlayingArtwork: UIImage?
    
    /// Skip interval for forward command (seconds).
    var skipForwardSeconds: Double = 30.0
    
    /// Skip interval for backward command (seconds).
    var skipBackwardSeconds: Double = 15.0
    
    /// Called when play command is triggered.
    var onPlay: (() -> Void)?
    
    /// Called when pause command is triggered.
    var onPause: (() -> Void)?
    
    /// Called when toggle play/pause command is triggered.
    var onTogglePlayPause: ((Bool) -> Void)?
    
    /// Called when skip forward command is triggered.
    var onSkipForward: (() -> Void)?
    
    /// Called when skip backward command is triggered.
    var onSkipBackward: (() -> Void)?
    
    /// Called when seek command is triggered.
    var onSeek: ((Double) -> Void)?
    
    private init() {}
    
    /// Sets up the remote command center and registers command handlers.
    ///
    /// Call this once during app initialization.
    func setup() {
        guard !isConfigured else { return }
        isConfigured = true
        
        #if os(iOS)
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onPlay?()
            }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onPause?()
            }
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noActionableNowPlayingItem }
            
            Task { @MainActor in
                self.onTogglePlayPause?(self.isPlaying)
            }
            return .success
        }
        
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onSkipForward?()
            }
            return .success
        }
        
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onSkipBackward?()
            }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .noActionableNowPlayingItem
            }
            
            Task { @MainActor in
                self?.onSeek?(event.positionTime)
            }
            return .success
        }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        
        updateSkipIntervals()
        #endif
    }
    
    /// Updates Now Playing info with current metadata.
    ///
    /// - Parameters:
    ///   - title: The book/chapter title
    ///   - duration: Total duration in seconds
    ///   - currentTime: Current playback position in seconds
    ///   - artwork: Cover art image (optional)
    func updateNowPlayingInfo(title: String, duration: Double, currentTime: Double, artwork: UIImage? = nil) {
        #if os(iOS)
        nowPlayingTitle = title
        nowPlayingDuration = duration
        nowPlayingArtwork = artwork
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = title.isEmpty ? "StoryCast" : title
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
        
        if let artwork = artwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        #endif
    }
    
    /// Updates the elapsed playback time in Now Playing info.
    ///
    /// - Parameter currentTime: Current playback position in seconds
    func updateElapsedTime(_ currentTime: Double) {
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }
    
    /// Updates the playback rate in Now Playing info.
    ///
    /// - Parameters:
    ///   - rate: Playback rate (0 = paused, 1 = normal, >1 = faster)
    ///   - isPlaying: Whether currently playing
    func updatePlaybackRate(rate: Float, isPlaying: Bool) {
        #if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }
    
    /// Updates the skip intervals for remote commands.
    func updateSkipIntervals() {
        #if os(iOS)
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardSeconds)]
        #endif
    }
    
    #if os(iOS)
    var isPlaying: Bool = false
    #endif
}
