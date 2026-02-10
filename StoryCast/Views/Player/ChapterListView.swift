import SwiftUI
import SwiftData
import os

struct ChapterListView: View {
    let book: Book
    let onChapterSelected: ((_ sortedChapters: [Chapter], _ selectedIndex: Int) -> Void)?

    init(
        book: Book,
        onChapterSelected: ((_ sortedChapters: [Chapter], _ selectedIndex: Int) -> Void)? = nil
    ) {
        self.book = book
        self.onChapterSelected = onChapterSelected
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var audioPlayer = AudioPlayerService.shared

    private var sortedChapters: [Chapter] {
        book.chapters.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        NavigationStack {
            List {
                if sortedChapters.isEmpty {
                    ContentUnavailableView {
                        Label("No Chapters", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("This book doesn't contain chapter markers.")
                    }
                } else {
                    ForEach(sortedChapters) { chapter in
                        Button(action: {
                            HapticManager.impact(.medium)
                            selectChapter(chapter)
                        }) {
                            HStack(spacing: LayoutDefaults.mediumSpacing) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title)
                                        .font(.headline)
                                    Text(TimeFormatter.playback(chapter.startTime))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isCurrentChapter(chapter) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapter.title), starts at \(TimeFormatter.playback(chapter.startTime))")
                        .accessibilityHint(isCurrentChapter(chapter) ? "Currently playing" : "Tap to play this chapter")
                    }
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func selectChapter(_ chapter: Chapter) {
        audioPlayer.seek(to: chapter.startTime)
        audioPlayer.updateNowPlayingTitle("\(book.title) - \(chapter.title)")
        AccessibilityNotifications.announce("Playing chapter \(chapter.title)")
        book.lastPlaybackPosition = chapter.startTime
        do {
            try modelContext.save()
        } catch {
            AppLogger.ui.error("Error saving chapter selection: \(error.localizedDescription, privacy: .private)")
        }
        let chapters = sortedChapters
        if let selectedIndex = chapters.firstIndex(where: { $0 === chapter }) {
            onChapterSelected?(chapters, selectedIndex)
        }
        dismiss()
    }

    private func isCurrentChapter(_ chapter: Chapter) -> Bool {
        audioPlayer.currentTime >= chapter.startTime && audioPlayer.currentTime < chapter.endTime
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    if let container = try? ModelContainer(for: Book.self, Chapter.self, Folder.self, configurations: config) {
        let book = Book(title: "Sample", localFileName: "sample.mp3", duration: 120)
        let chapters = [
            Chapter(title: "Intro", startTime: 0, endTime: 30, book: book),
            Chapter(title: "Chapter 1", startTime: 30, endTime: 90, book: book),
            Chapter(title: "Chapter 2", startTime: 90, endTime: 120, book: book)
        ]
        chapters.forEach { container.mainContext.insert($0) }
        container.mainContext.insert(book)
        return ChapterListView(book: book)
            .modelContainer(container)
    }
    let book = Book(title: "Sample", localFileName: "sample.mp3", duration: 120)
    return ChapterListView(book: book)
}
