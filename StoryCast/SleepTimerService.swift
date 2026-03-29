import Foundation
import Combine

/// Manages sleep timer functionality for audiobook playback
@MainActor
class SleepTimerService: ObservableObject {
    static let shared = SleepTimerService()
    
    @Published var isActive: Bool = false
    @Published var remainingTime: Int = 0 // in seconds
    @Published var totalTime: Int = 0 // in seconds
    @Published private(set) var isWaitingForPlaybackStart: Bool = false
    
    private var timer: Timer?
    private var endOfChapterTime: Double?
    private var timerGeneration: Int = 0
    private var playbackStateCancellable: AnyCancellable?
    
    // Presets in minutes
    let presets: [Int] = SleepTimerDefaults.availableDurations
    


    // Import needed for AudioPlayerService
    private var audioPlayerService: AudioPlayerService { AudioPlayerService.shared }
    
    private init() {
        observePlaybackState()
    }
    
    /// Start timer with preset duration in minutes
    func start(minutes: Int) {
        cancel(announce: false) // Clear any existing timer

        totalTime = minutes * 60
        remainingTime = totalTime
        isActive = true
        endOfChapterTime = nil
        AccessibilityNotifications.announce("Sleep timer set for \(minutes) minutes")
        
        if audioPlayerService.isPlaying {
            isWaitingForPlaybackStart = false
            startTimedCountdown(for: timerGeneration)
        } else {
            isWaitingForPlaybackStart = true
        }
    }
    
    /// Special mode: stop at end of current chapter
    func startForEndOfChapter(currentTime: Double, chapterEndTime: Double) {
        cancel(announce: false)

        // If we're already past chapter end, don't start
        guard currentTime < chapterEndTime else { return }
        
        endOfChapterTime = chapterEndTime
        isActive = true
        isWaitingForPlaybackStart = false
        remainingTime = 0 // Show 0 since we don't know exact duration
        totalTime = 0
        AccessibilityNotifications.announce("Sleep timer set for end of current chapter")

        startEndOfChapterPolling(for: timerGeneration)
    }
    
    /// Add more time to the current timer
    func extendBy(minutes: Int) {
        guard isActive else { return }
        AccessibilityNotifications.announce("Sleep timer extended by \(minutes) minutes")
        
        // If in end-of-chapter mode, switch to a time-based timer
        if endOfChapterTime != nil {
            timer?.invalidate()
            timer = nil
            endOfChapterTime = nil
            timerGeneration += 1
            
            let duration = minutes * 60
            totalTime = duration
            remainingTime = duration

            if audioPlayerService.isPlaying {
                isWaitingForPlaybackStart = false
                startTimedCountdown(for: timerGeneration)
            } else {
                isWaitingForPlaybackStart = true
            }
        } else {
            remainingTime += minutes * 60
            totalTime += minutes * 60
            if !audioPlayerService.isPlaying {
                isWaitingForPlaybackStart = true
            }
        }
    }
    
    /// Cancel the current timer
    func cancel(announce: Bool = true) {
        let wasActive = isActive
        timerGeneration += 1
        timer?.invalidate()
        timer = nil
        isActive = false
        isWaitingForPlaybackStart = false
        remainingTime = 0
        totalTime = 0
        endOfChapterTime = nil
        if announce, wasActive {
            AccessibilityNotifications.announce("Sleep timer canceled")
        }
    }
    
    private func timerFired() {
        cancel(announce: false)
        // Pause playback
        audioPlayerService.pause()
        AccessibilityNotifications.announce("Sleep timer ended. Playback paused")
    }

    private func observePlaybackState() {
        playbackStateCancellable = audioPlayerService.$isPlaying
            .sink { [weak self] isPlaying in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackStateChange(isPlaying: isPlaying)
                }
            }
    }

    private func handlePlaybackStateChange(isPlaying: Bool) {
        guard isActive else { return }
        guard endOfChapterTime == nil else {
            isWaitingForPlaybackStart = false
            return
        }

        if isPlaying {
            guard remainingTime > 0 else {
                timerFired()
                return
            }

            if timer == nil {
                isWaitingForPlaybackStart = false
                startTimedCountdown(for: timerGeneration)
            }
        } else {
            timer?.invalidate()
            timer = nil
            if remainingTime > 0 {
                isWaitingForPlaybackStart = true
            }
        }
    }

    private func startTimedCountdown(for generation: Int) {
        timer?.invalidate()
        timer = Timer(timeInterval: TimerDefaults.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.timerGeneration == generation else { return }
                guard self.audioPlayerService.isPlaying else {
                    self.handlePlaybackStateChange(isPlaying: false)
                    return
                }

                self.remainingTime = max(0, self.remainingTime - 1)
                if self.remainingTime <= 0 {
                    self.timerFired()
                }
            }
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func startEndOfChapterPolling(for generation: Int) {
        timer?.invalidate()
        timer = Timer(timeInterval: TimerDefaults.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.timerGeneration == generation else { return }
                guard self.audioPlayerService.isPlaying else { return }
                let currentTime = self.audioPlayerService.currentTime
                if currentTime >= (self.endOfChapterTime ?? 0) {
                    self.timerFired()
                }
            }
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
}
