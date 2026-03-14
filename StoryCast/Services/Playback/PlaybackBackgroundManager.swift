import Foundation
import os

#if os(iOS)
import UIKit
#endif

protocol PlaybackLifecycleDelegate: AnyObject {
    func playbackWillResignActive()
    func playbackDidEnterBackground()
    func playbackWillEnterForeground()
    func playbackDidBecomeActive()
    func playbackProtectedDataWillBecomeUnavailable()
    func playbackProtectedDataDidBecomeAvailable()
}

@MainActor
final class PlaybackBackgroundManager {
    static let shared = PlaybackBackgroundManager()
    
    weak var delegate: PlaybackLifecycleDelegate?
    
    var isPlaying = false {
        didSet {
            #if os(iOS)
            if !isPlaying { endBackgroundTaskIfNeeded() }
            #endif
        }
    }
    
    #if os(iOS)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var lifecycleObservers: [Any] = []
    
    private init() {}
    
    func setup() {
        #if os(iOS)
        let center = NotificationCenter.default
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillResignActive() }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidEnterBackground() }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillEnterForeground() }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidBecomeActive() }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleProtectedDataWillBecomeUnavailable() }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleProtectedDataDidBecomeAvailable() }
        })
        #endif
    }
    
    func handleAppDidEnterBackground() {
        #if os(iOS)
        guard isPlaying else {
            endBackgroundTaskIfNeeded()
            return
        }
        beginBackgroundTaskIfNeeded()
        #endif
    }
    
    func handleAppDidBecomeActive() {
        #if os(iOS)
        guard isPlaying else {
            endBackgroundTaskIfNeeded()
            return
        }
        #endif
    }
    
    #if os(iOS)
    private func handleWillResignActive() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
        delegate?.playbackWillResignActive()
    }
    
    private func handleDidEnterBackground() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
        delegate?.playbackDidEnterBackground()
    }
    
    private func handleWillEnterForeground() {
        guard isPlaying else { return }
        delegate?.playbackWillEnterForeground()
    }
    
    private func handleDidBecomeActive() {
        guard isPlaying else { return }
        delegate?.playbackDidBecomeActive()
    }
    
    private func handleProtectedDataWillBecomeUnavailable() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
        delegate?.playbackProtectedDataWillBecomeUnavailable()
    }
    
    private func handleProtectedDataDidBecomeAvailable() {
        guard isPlaying else { return }
        delegate?.playbackProtectedDataDidBecomeAvailable()
    }
    
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskId == .invalid else {
            AppLogger.playback.debug("beginBackgroundTaskIfNeeded: task already active")
            return
        }
        
        AppLogger.playback.info("beginBackgroundTaskIfNeeded: starting background task")
        
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "StoryCastPlayback") { [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                AppLogger.playback.warning("Background task expired; ending task.")
                self.endBackgroundTaskIfNeeded()
            }
        }
        
        if backgroundTaskId == .invalid {
            AppLogger.playback.warning("Failed to start background task.")
        } else {
            AppLogger.playback.info("beginBackgroundTaskIfNeeded: background task started with id \(self.backgroundTaskId.rawValue)")
        }
    }
    
    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
    #endif
}