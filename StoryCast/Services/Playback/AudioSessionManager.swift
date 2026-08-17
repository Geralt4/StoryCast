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
    
    private(set) var isAudioSessionActive = false
    
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var activationTask: Task<Void, Never>?
    
    private init() {}
    
    func setup() {
        #if os(iOS)
        Task.detached(priority: .userInitiated) {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
                AppLogger.playback.info("Audio session configured for background playback")
            } catch {
                AppLogger.playback.error("Failed to set up audio session: \(error.localizedDescription, privacy: .private)")
            }
        }
        setupInterruptionObserver()
        setupRouteChangeObserver()
        #endif
    }
    
    func ensureActive() async throws {
        #if os(iOS)
        if isAudioSessionActive {
            return
        }
        if let activationTask {
            await activationTask.value
            guard isAudioSessionActive else {
                throw AudioSessionActivationError.failed
            }
            return
        }

        let task = Task { @MainActor in
            do {
                try await activateSession()
                if !Task.isCancelled {
                    isAudioSessionActive = true
                    AppLogger.playback.info("Audio session activated")
                }
            } catch {
                AppLogger.playback.error("Failed to activate audio session: \(error.localizedDescription, privacy: .private)")
            }
        }
        activationTask = task
        await task.value
        activationTask = nil

        guard isAudioSessionActive else {
            throw AudioSessionActivationError.failed
        }
        #endif
    }

    #if os(iOS)
    private func activateSession() async throws {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                try await performActivation()
                return
            } catch {
                AppLogger.playback.warning("Audio session activation attempt \(attempt) failed: \(error.localizedDescription, privacy: .private)")
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                }
            }
        }
        throw AudioSessionActivationError.failed
    }

    private func performActivation() async throws {
        let options: AVAudioSession.SetActiveOptions = [.notifyOthersOnDeactivation]
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(true, options: options)
        }.value
    }
    
    func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            delegate?.audioSessionInterruptionBegan()
        case .ended:
            delegate?.audioSessionInterruptionEnded()
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
            
            guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
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

#if os(iOS)
enum AudioSessionActivationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Unable to activate the audio session."
    }
}
#endif
