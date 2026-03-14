import Foundation
import os

#if os(iOS)
import UIKit
#endif

/// Manages background playback tasks and app lifecycle events.
///
/// `PlaybackBackgroundManager` handles:
/// - Background task registration for continued playback
/// - App lifecycle event handling (background, foreground, resign active)
/// - Protected data availability notifications
///
/// ## Background Playback
///
/// Registers a background task when app enters background while playing,
/// allowing audio to continue for up to several minutes.
///
/// ## Usage
///
/// ```swift
/// let manager = PlaybackBackgroundManager.shared
/// manager.setup()
/// 
/// // When playback starts/stops
/// manager.isPlaying = true
/// manager.handleAppDidEnterBackground()
/// ```
@MainActor
final class PlaybackBackgroundManager {
    static let shared = PlaybackBackgroundManager()
    
    /// Whether audio is currently playing.
    var isPlaying = false {
        didSet {
            #if os(iOS)
            if !isPlaying {
                endBackgroundTaskIfNeeded()
            }
            #endif
        }
    }
    
    /// Called when app is about to resign active.
    var onWillResignActive: (() -> Void)?
    
    /// Called when app did enter background.
    var onDidEnterBackground: (() -> Void)?
    
    /// Called when app will enter foreground.
    var onWillEnterForeground: (() -> Void)?
    
    /// Called when app did become active.
    var onDidBecomeActive: (() -> Void)?
    
    /// Called when protected data will become unavailable.
    var onProtectedDataWillBecomeUnavailable: (() -> Void)?
    
    /// Called when protected data did become available.
    var onProtectedDataDidBecomeAvailable: (() -> Void)?
    
    #if os(iOS)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var lifecycleObservers: [Any] = []
    
    private init() {}
    
    /// Sets up lifecycle event observers.
    ///
    /// Call this once during app initialization.
    func setup() {
        #if os(iOS)
        let center = NotificationCenter.default
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleWillResignActive()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleDidEnterBackground()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleWillEnterForeground()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleDidBecomeActive()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleProtectedDataWillBecomeUnavailable()
            }
        })
        
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleProtectedDataDidBecomeAvailable()
            }
        })
        #endif
    }
    
    /// Handles app entering background state.
    ///
    /// Starts background task if audio is playing.
    func handleAppDidEnterBackground() {
        #if os(iOS)
        guard isPlaying else {
            endBackgroundTaskIfNeeded()
            return
        }
        beginBackgroundTaskIfNeeded()
        #endif
    }
    
    /// Handles app becoming active.
    ///
    /// Ends background task if not playing.
    func handleAppDidBecomeActive() {
        #if os(iOS)
        guard isPlaying else {
            endBackgroundTaskIfNeeded()
            return
        }
        #endif
    }
    
    // MARK: - Private
    
    #if os(iOS)
    private func handleWillResignActive() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
    }
    
    private func handleDidEnterBackground() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
    }
    
    private func handleWillEnterForeground() {
        guard isPlaying else { return }
    }
    
    private func handleDidBecomeActive() {
        guard isPlaying else { return }
    }
    
    private func handleProtectedDataWillBecomeUnavailable() {
        guard isPlaying else { return }
        beginBackgroundTaskIfNeeded()
    }
    
    private func handleProtectedDataDidBecomeAvailable() {
        guard isPlaying else { return }
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
