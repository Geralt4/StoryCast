import Foundation
import os

#if os(iOS)
import UIKit
import MediaPlayer

protocol RemoteCommandDelegate: AnyObject {
    func remoteCommandPlay()
    func remoteCommandPause()
    func remoteCommandTogglePlayPause(isPlaying: Bool)
    func remoteCommandSkipForward()
    func remoteCommandSkipBackward()
    func remoteCommandSeek(to time: Double)
}
#endif

@MainActor
final class RemoteCommandHandler {
    static let shared = RemoteCommandHandler()
    
    #if os(iOS)
    weak var delegate: RemoteCommandDelegate?
    var isPlaying: Bool = false
    private var isConfigured = false
    private var nowPlayingTitle: String = ""
    private var nowPlayingDuration: Double = 0.0
    private var nowPlayingArtwork: UIImage?
    #else
    private var isConfigured = false
    #endif
    
    var skipForwardSeconds: Double = 30.0
    var skipBackwardSeconds: Double = 15.0
    
    private init() {}
    
    func setup() {
        #if os(iOS)
        guard !isConfigured else { return }
        isConfigured = true
        
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.delegate?.remoteCommandPlay() }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.delegate?.remoteCommandPause() }
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.delegate?.remoteCommandTogglePlayPause(isPlaying: self.isPlaying) }
            return .success
        }
        
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.delegate?.remoteCommandSkipForward() }
            return .success
        }
        
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.delegate?.remoteCommandSkipBackward() }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .noActionableNowPlayingItem }
            Task { @MainActor in self?.delegate?.remoteCommandSeek(to: event.positionTime) }
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
    
    #if os(iOS)
    func updateNowPlayingInfo(title: String, duration: Double, currentTime: Double, artwork: UIImage? = nil) {
        nowPlayingTitle = title
        nowPlayingDuration = duration
        nowPlayingArtwork = artwork
        
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "StoryCast" : title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue
        ]
        
        if let artwork = artwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateElapsedTime(_ currentTime: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func updatePlaybackRate(rate: Float, isPlaying: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func updateSkipIntervals() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardSeconds)]
    }
    #endif
}