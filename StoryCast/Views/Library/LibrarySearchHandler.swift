import Foundation
import SwiftData

/// Handles search filtering and debouncing for library content.
///
/// `LibrarySearchHandler` provides:
/// - Debounced search text processing (150ms delay)
/// - Folder filtering by name match
/// - Book filtering with deduplication
/// - Cached search results for performance
///
/// ## Search Performance
///
/// Uses debouncing to avoid excessive filtering during typing,
/// and caches results to prevent redundant computations.
///
/// ## Usage
///
/// ```swift
/// @State private var searchHandler = LibrarySearchHandler()
/// searchHandler.updateSearchText("query", folders: folders, books: allBooks)
/// let filteredFolders = searchHandler.getFilteredFolders(allFolders: folders)
/// let filteredBooks = searchHandler.getFilteredBooks(allBooks: allBooks)
/// ```
@MainActor
@Observable
final class LibrarySearchHandler {
    /// Debounce interval for search updates (150ms)
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000
    
    /// The current search text input by the user.
    var searchText = ""
    
    /// Cached filtered books from the last search.
    private(set) var cachedFilteredBooks: [Book] = []
    
    /// Cached filtered folders from the last search.
    private(set) var cachedFilteredFolders: [Folder] = []
    
    /// The last search text that was processed.
    private var lastSearchText: String = ""
    
    /// Task for debouncing search updates.
    private var searchDebounceTask: Task<Void, Never>?
    
    init() {}
    
    /// Updates search text and triggers debounced filtering.
    ///
    /// - Parameters:
    ///   - searchText: The current search query
    ///   - folders: All folders to filter
    ///   - books: All books to filter
    func updateSearchText(_ searchText: String, folders: [Folder], books: [Book]) {
        self.searchText = searchText
        
        searchDebounceTask?.cancel()
        
        let currentSearchText = normalizedSearchText
        guard currentSearchText != lastSearchText else { return }
        
        searchDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                
                let query = currentSearchText.lowercased()
                
                self.cachedFilteredFolders = folders.filter { $0.name.lowercased().contains(query) }
                self.cachedFilteredBooks = self.deduplicatedBooks(
                    books.filter { $0.matchesSearch(query: query) }
                )
                self.lastSearchText = currentSearchText
            } catch {
                // Task cancelled
            }
        }
    }
    
    /// Whether a search query is active.
    var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }
    
    /// Returns folders filtered by current search.
    ///
    /// - Parameter allFolders: All folders from SwiftData.
    /// - Returns: Filtered folders if searching, otherwise all folders.
    func getFilteredFolders(allFolders: [Folder]) -> [Folder] {
        guard isSearching else { return allFolders }
        
        if normalizedSearchText == lastSearchText && !cachedFilteredFolders.isEmpty {
            return cachedFilteredFolders
        }
        
        return cachedFilteredFolders
    }
    
    /// Returns books filtered by current search.
    ///
    /// - Parameter allBooks: All books from SwiftData.
    /// - Returns: Filtered books if searching, otherwise all books.
    func getFilteredBooks(allBooks: [Book]) -> [Book] {
        guard isSearching else { return allBooks }
        
        if normalizedSearchText == lastSearchText && !cachedFilteredBooks.isEmpty {
            return cachedFilteredBooks
        }
        
        return cachedFilteredBooks
    }

    func onDisappear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }
    
    /// The search text normalized (trimmed whitespace and newlines).
    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private
    
    private func deduplicatedBooks(_ books: [Book]) -> [Book] {
        var seenKeys = Set<String>()
        var deduplicatedBooks: [Book] = []
        
        for book in books {
            let deduplicationKey = "\(book.normalizedTitle)|\(book.normalizedAuthor)|\(Int(book.duration.rounded()))"
            
            if seenKeys.insert(deduplicationKey).inserted {
                deduplicatedBooks.append(book)
            }
        }
        
        return deduplicatedBooks
    }
}
