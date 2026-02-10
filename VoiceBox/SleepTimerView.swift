import SwiftUI

/// Sheet view for controlling sleep timer
struct SleepTimerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    
    // ADD: Accept book as parameter
    let book: Book
    
    var body: some View {
        NavigationStack {
            VStack(spacing: LayoutDefaults.contentPadding) {
                // Current Status
                if sleepTimer.isActive {
                    VStack(spacing: LayoutDefaults.smallSpacing) {
                        Text("Timer Active")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        if sleepTimer.totalTime > 0 {
                            if sleepTimer.isWaitingForPlaybackStart {
                                Text("Starts when playback begins")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("\(TimeFormatter.human(sleepTimer.remainingTime)) queued")
                                    .font(.title2)
                                    .monospacedDigit()
                            } else {
                                Text("\(TimeFormatter.human(sleepTimer.remainingTime)) remaining")
                                    .font(.title2)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("End of chapter")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, LayoutDefaults.sectionSpacing)
                } else {
                    Text("Set Sleep Timer")
                        .font(.headline)
                        .padding(.vertical, LayoutDefaults.sectionSpacing)
                }
                
                // Preset Buttons
                if !sleepTimer.isActive {
                    Text("Duration")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LayoutDefaults.mediumSpacing) {
                        ForEach(sleepTimer.presets, id: \.self) { minutes in
                            Button("\(minutes) min") {
                                HapticManager.notification(.success)
                                sleepTimer.start(minutes: minutes)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .accessibilityLabel("Set timer for \(minutes) minutes")
                        }
                    }
                    
                    // End of Chapter Button — only show if book has chapters
                    if !book.chapters.isEmpty {
                        Button(action: {
                            // Get current chapter end time
                            // This would need to be passed in or accessed via Book context
                            // For now, we'll just show that this mode is available
                            if let currentBook = getCurrentBook(),
                               let currentChapter = getCurrentChapter(for: currentBook) {
                                HapticManager.notification(.success)
                                sleepTimer.startForEndOfChapter(
                                    currentTime: AudioPlayerService.shared.currentTime,
                                    chapterEndTime: currentChapter.endTime
                                )
                            }
                        }) {
                            Label("End of Current Chapter", systemImage: "book.closed")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .padding(.top, LayoutDefaults.smallSpacing)
                        .accessibilityLabel("Set timer to end of current chapter")
                    }
                    
                } else {
                    // Extend / Cancel Controls
                    HStack(spacing: LayoutDefaults.mediumSpacing) {
                        ForEach(SleepTimerDefaults.extensionOptions, id: \.self) { minutes in
                            Button("+\(minutes)m") {
                                HapticManager.impact(.light)
                                sleepTimer.extendBy(minutes: minutes)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Extend timer by \(minutes) minutes")
                        }
                    }
                    
                    Button(role: .destructive, action: {
                        HapticManager.notification(.warning)
                        sleepTimer.cancel()
                        dismiss()
                    }) {
                        Label("Cancel Timer", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, LayoutDefaults.smallSpacing)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // Placeholder functions - these would need actual implementation
    // with proper Book and Chapter context passed to the view
    private func getCurrentBook() -> Book? {
        book
    }
    
    private func getCurrentChapter(for book: Book) -> (startTime: Double, endTime: Double)? {
        // Find current chapter based on current time
        let currentTime = AudioPlayerService.shared.currentTime
        let sortedChapters = book.chapters.sorted { $0.startTime < $1.startTime }
        
        for chapter in sortedChapters {
            if currentTime >= chapter.startTime && currentTime < chapter.endTime {
                return (chapter.startTime, chapter.endTime)
            }
        }
        return nil
    }
}
