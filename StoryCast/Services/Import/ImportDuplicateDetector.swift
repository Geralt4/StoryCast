import Foundation
import AVFoundation
import SwiftData
import os

/// Detects duplicate audiobooks during import to prevent library clutter.
///
/// `ImportDuplicateDetector` uses a multi-factor approach:
/// 1. Normalized title match (case-insensitive, trimmed)
/// 2. Duration match (within 1 second tolerance)
/// 3. Author match (when both have metadata)
/// 4. File size match (fallback when author unavailable)
///
/// ## Duplicate Detection Criteria
///
/// A book is considered duplicate if:
/// - Normalized titles match exactly
/// - Durations match within 1 second
/// - AND either:
///   - Authors match (when both available)
///   - File sizes match (when author unavailable)
///
/// ## Usage
///
/// ```swift
/// let detector = ImportDuplicateDetector.shared
/// let isDuplicate = detector.isDuplicate(
///     title: "Book Title",
///     duration: 3600,
///     author: "Author Name",
///     fileSize: 12345678,
///     in: context
/// )
/// ```
@MainActor
final class ImportDuplicateDetector {
    static let shared = ImportDuplicateDetector()
    
    private let libraryURL = StorageManager.shared.storyCastLibraryURL
    
    private init() {}
    
    /// Checks if a book with the given attributes already exists in the library.
    ///
    /// - Parameters:
    ///   - title: The book title
    ///   - duration: Audio duration in seconds
    ///   - author: Optional author from metadata
    ///   - fileSize: File size in bytes
    ///   - context: SwiftData context for fetching existing books
    /// - Returns: `true` if a duplicate exists
    func isDuplicate(
        title: String,
        duration: Double,
        author: String?,
        fileSize: Int64?,
        in context: ModelContext
    ) -> Bool {
        let existingBooks: [Book]
        do {
            existingBooks = try context.fetch(FetchDescriptor<Book>())
        } catch {
            AppLogger.importService.error("Failed to fetch books for duplicate detection: \(error.localizedDescription, privacy: .private)")
            return false
        }
        
        let normalizedTitle = Self.normalizedToken(title)
        let normalizedAuthor = Self.normalizedToken(author)
        
        return existingBooks.contains { existingBook in
            guard Self.normalizedToken(existingBook.title) == normalizedTitle else {
                return false
            }
            
            guard abs(existingBook.duration - duration) < 1.0 else {
                return false
            }
            
            let existingFileURL = libraryURL.appendingPathComponent(existingBook.localFileName)
            guard FileManager.default.fileExists(atPath: existingFileURL.path) else {
                return false
            }
            
            let existingFileSize = Self.fileSizeInBytes(at: existingFileURL)
            let existingAuthor = Self.normalizedToken(existingBook.author)
            
            if let fileSize,
               let existingFileSize,
               fileSize != existingFileSize {
                return false
            }
            
            if !normalizedAuthor.isEmpty && !existingAuthor.isEmpty {
                return existingAuthor == normalizedAuthor
            }
            
            return true
        }
    }
    
    // MARK: - Private Helpers
    
    /// Normalizes a string for duplicate comparison.
    private nonisolated static func normalizedToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    
    /// Gets file size in bytes for a file at the given URL.
    private nonisolated static func fileSizeInBytes(at url: URL) -> Int64? {
        if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = resourceValues.fileSize {
            return Int64(fileSize)
        }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            return sizeNumber.int64Value
        }
        
        return nil
    }
}
