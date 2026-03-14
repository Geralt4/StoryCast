import AVFoundation
import Foundation
import os

#if os(iOS)
import UIKit

protocol AudioSessionDelegate: AnyObject {
    func audioSessionInterruptionBegan()
    func audioSessionInterruptionEnded()
    func audioSessionRouteChanged(reason: AVAudioSession.RouteChangeReason)
}
#endif

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    #if os(iOS)
    weak var delegate: AudioSessionDelegate?
    #endif
    
    var isAudioSessionActive = false
    
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    
    private init() {}
    
    func setup() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            isAudioSessionActive = true
            AppLogger.playback.info("Audio session configured for background playback")
        } catch {
            AppLogger.playback.error("Failed to set up audio session: \(error.localizedDescription, privacy: .private)")
        }
        setupInterruptionObserver()
        setupRouteChangeObserver()
        #endif
    }
    
    func ensureActive() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = true
        } catch {
            AppLogger.playback.error("Failed to activate audio session: \(error.localizedDescription, privacy: .private)")
        }
        #endif
    }
    
    #if os(iOS)
    func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            delegate?.audioSessionInterruptionBegan()
        case .ended:
            if options.contains(.shouldResume) {
                delegate?.audioSessionInterruptionEnded()
            }
        @unknown default:
            break
        }
    }
    
    func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        delegate?.audioSessionRouteChanged(reason: reason)
    }
    
    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) ?? .ended
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, options: options)
            }
        }
    }
    
    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown
            
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason: reason)
            }
        }
    }
    #endif
}