import SwiftUI
import SwiftData

/// Displays all books in a specific Audiobookshelf library.
/// Tapping a book navigates to the player which streams from the server.
struct RemoteLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var remoteLibrary = RemoteLibraryService.shared

    let server: ABSServer
    let library: ABSLibrary

    @State private var searchText: String = ""

    private var filteredItems: [ABSLibraryItem] {
        guard !searchText.isEmpty else { return remoteLibrary.remoteItems }
        let query = searchText.lowercased()
        return remoteLibrary.remoteItems.filter {
            $0.title.lowercased().contains(query) ||
            ($0.authorName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if remoteLibrary.isLoading && remoteLibrary.remoteItems.isEmpty {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = remoteLibrary.error, remoteLibrary.remoteItems.isEmpty {
                ContentUnavailableView {
                    Label("Could Not Load Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Retry") {
                        Task { await remoteLibrary.fetchItems(libraryId: library.id, container: modelContext.container) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if filteredItems.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                bookList
            }
        }
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search books")
        .task { await remoteLibrary.fetchItems(libraryId: library.id, container: modelContext.container) }
        .refreshable {
            // Retry failed cover art downloads on pull-to-refresh before reloading.
            remoteLibrary.retryAllCoverArtDownloads(container: modelContext.container)
            await remoteLibrary.fetchItems(libraryId: library.id, container: modelContext.container)
        }
    }

    // MARK: - Book List

    private var bookList: some View {
        List {
            ForEach(filteredItems) { item in
                remoteBookRow(item)
                    .onAppear {
                        // Trigger next page load when near the end.
                        if item.id == filteredItems.last?.id {
                            Task { await remoteLibrary.loadNextPage(container: modelContext.container) }
                        }
                    }
            }

            if remoteLibrary.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private func remoteBookRow(_ item: ABSLibraryItem) -> some View {
        // Find the matching SwiftData Book to navigate to PlayerView.
        RemoteBookRowNavigator(item: item, server: server)
    }
}

// MARK: - Remote Book Row Navigator

/// Looks up the SwiftData `Book` for a remote item and provides a NavigationLink to PlayerView.
private struct RemoteBookRowNavigator: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var remoteLibrary = RemoteLibraryService.shared
    let item: ABSLibraryItem
    let server: ABSServer

    @State private var book: Book?

    var body: some View {
        Group {
            if let book {
                NavigationLink(destination: PlayerView(book: book)) {
                    rowContent
                }
            } else {
                rowContent
                    .foregroundStyle(.secondary)
            }
        }
        .task { fetchBook() }
    }

    private var coverArtFailure: CoverArtFailure? {
        guard let book else { return nil }
        let compoundKey = "\(server.id.uuidString)_\(book.id.uuidString)"
        return remoteLibrary.coverArtFailures[compoundKey]
    }

    private var rowContent: some View {
        HStack(spacing: LayoutDefaults.mediumSpacing) {
            // Cover art with failure indicator overlay
            ZStack(alignment: .bottomTrailing) {
                CoverArtThumbnail(book: book)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutDefaults.smallCornerRadius))

                if let failure = coverArtFailure {
                    Button {
                        guard let book else { return }
                        remoteLibrary.retryCoverArtDownload(for: book.id, container: modelContext.container)
                    } label: {
                        Image(systemName: failure.isExhausted ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.orange, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry cover art download")
                    .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: LayoutDefaults.tinySpacing) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(2)

                if let author = item.authorName {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: LayoutDefaults.smallSpacing) {
                    BookSourceBadge(isDownloaded: book?.isDownloaded ?? false)
                    Text(formatDuration(item.duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Progress indicator
            if let book, book.lastPlaybackPosition > 0 {
                CircularProgressView(progress: book.lastPlaybackPosition / max(book.duration, 1))
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.vertical, LayoutDefaults.tinySpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)\(item.authorName.map { ", by \($0)" } ?? "")")
    }

    private func fetchBook() {
        let remoteId = item.id
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.remoteItemId == remoteId }
        )
        descriptor.fetchLimit = 1
        book = try? modelContext.fetch(descriptor).first
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Cover Art Thumbnail

private struct CoverArtThumbnail: View {
    let book: Book?

    var body: some View {
        Group {
            if let book,
               let fileName = book.coverArtFileName,
               let image = UIImage(contentsOfFile: StorageManager.shared.coverArtURL(for: fileName, isRemote: book.isRemote).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: LayoutDefaults.smallCornerRadius)
                    .fill(Color.secondary.opacity(ColorDefaults.subtleOpacity))
                    .overlay {
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}

// MARK: - Circular Progress

private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    NavigationStack {
        RemoteLibraryView(
            server: ABSServer(name: "Home", url: "https://abs.home.local", username: "admin"),
            library: ABSLibrary(id: "lib1", name: "Audiobooks", mediaType: "book", displayOrder: 1, icon: nil, createdAt: nil, lastUpdate: nil)
        )
    }
    .modelContainer(for: [ABSServer.self, Book.self, Folder.self, Chapter.self], inMemory: true)
}
