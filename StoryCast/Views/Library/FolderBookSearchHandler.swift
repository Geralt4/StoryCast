import Foundation
import Observation

@MainActor
@Observable
final class FolderBookSearchHandler {
    var searchText = ""
    private(set) var cachedFilteredBooks: [Book] = []

    private var lastSearchText = ""
    private var searchDebounceTask: Task<Void, Never>?

    func updateSearchText(_ searchText: String, books: [Book]) {
        self.searchText = searchText
        searchDebounceTask?.cancel()

        let currentSearchText = normalizedSearchText
        guard currentSearchText != lastSearchText else { return }

        searchDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PerformanceDefaults.searchDebounceNanoseconds)
                guard !Task.isCancelled else { return }

                self.cachedFilteredBooks = books.filter { $0.matchesSearch(query: currentSearchText) }
                self.lastSearchText = currentSearchText
            } catch {
                return
            }
        }
    }

    var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    func filteredBooks(from books: [Book]) -> [Book] {
        guard isSearching else { return books }

        if normalizedSearchText == lastSearchText && !cachedFilteredBooks.isEmpty {
            return cachedFilteredBooks
        }

        return cachedFilteredBooks
    }

    func onDisappear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
