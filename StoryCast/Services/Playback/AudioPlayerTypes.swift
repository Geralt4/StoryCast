import Foundation
import CoreMedia
import MediaPlayer

/// Internal types and constants for audio player service.
///
/// This file contains supporting types used by `AudioPlayerService` and related components.

// MARK: - Audio Player Constants

/// Constants for audio player configuration.
enum AudioPlayerConstants {
    /// Preferred timescale for CMTime operations (600 = high precision)
    static let preferredTimescale: CMTimeScale = 600
}

// MARK: - Now Playing Info Keys

/// Keys for Now Playing info dictionary.
enum NowPlayingInfoKeys {
    static let title = MPMediaItemPropertyTitle
    static let duration = MPMediaItemPropertyPlaybackDuration
    static let elapsedTime = MPNowPlayingInfoPropertyElapsedPlaybackTime
    static let playbackRate = MPNowPlayingInfoPropertyPlaybackRate
    static let defaultPlaybackRate = MPNowPlayingInfoPropertyDefaultPlaybackRate
    static let mediaType = MPMediaItemPropertyMediaType
    static let artwork = MPMediaItemPropertyArtwork
}
