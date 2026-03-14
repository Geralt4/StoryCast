import AVFoundation
import Foundation
import os

#if os(iOS)
import UIKit
#endif

/// Manages AVAudioSession configuration and audio interruption handling.
///
/// `AudioSessionManager` handles:
/// - Audio session setup and configuration for background playback
/// - Audio interruption handling (phone calls, Siri, alarms)
/// - Route change monitoring (headphones, Bluetooth)
/// - Audio session activation/deactivation
///
/// ## Audio Session Configuration
///
/// Uses `.playback` category with `.spokenAudio` mode and `.longFormAudio` policy:
/// - Enables background playback
/// - Provides lock screen and Control Center support
/// - Optimized for audiobook listening
///
/// ## Usage
///
/// ```swift
/// let sessionManager = AudioSessionManager.shared
/// try await sessionManager.setup()
/// sessionManager.handleInterruption(type: .began)
/// ```
@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    /// Whether the audio session is currently active.
    var isAudioSessionActive = false
    
    /// Called when an audio interruption begins.
    var onInterruptionBegan: (() -> Void)?
    
    /// Called when an audio interruption ends with resume option.
    var onInterruptionEnded: (() -> Void)?
    
    /// Called when audio route changes (e.g., headphones disconnected).
    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?
    
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    
    private init() {}
    
    /// Sets up the audio session for background audiobook playback.
    ///
    /// Configures the session with optimal settings for spoken audio content.
    /// Call this once during app initialization.
    func setup() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio
            )
            try session.setActive(true)
            isAudioSessionActive = true
            AppLogger.playback.info("Audio session configured successfully for background playback")
        } catch {
            AppLogger.playback.error("Failed to set up audio session: \(error.localizedDescription, privacy: .private)")
        }
        #endif
        
        setupInterruptionObserver()
        setupRouteChangeObserver()
    }
    
    /// Ensures the audio session is active, reactivating if needed.
    ///
    /// Call this before playback operations to ensure audio is ready.
    func ensureActive() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
        } catch {
            AppLogger.playback.error("Failed to activate audio session: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }
    
    /// Handles audio session interruption events.
    ///
    /// - Parameters:
    ///   - type: The type of interruption (began/ended)
    ///   - options: Interruption options (e.g., shouldResume)
    func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            onInterruptionBegan?()
            
        case .ended:
            if options.contains(.shouldResume) {
                onInterruptionEnded?()
            }
            
        @unknown default:
            break
        }
    }
    
    /// Handles audio route change events.
    ///
    /// - Parameter reason: The reason for the route change
    func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        onRouteChange?(reason)
    }
    
    // MARK: - Private
    
    private func setupInterruptionObserver() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) ?? .ended
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, options: options)
            }
        }
        #endif
    }
    
    private func setupRouteChangeObserver() {
        #if os(iOS)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt else {
                return
            }
            
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown
            
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason: reason)
            }
        }
        #endif
    }
}
