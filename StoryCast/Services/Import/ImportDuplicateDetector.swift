import Foundation
import CryptoKit
import SwiftData
import os

@MainActor
final class ImportDuplicateDetector {
    static let shared = ImportDuplicateDetector()

    /// Resolved on every read so the URL is always current. A captured `let`
    /// would go stale if the library directory is ever recreated (e.g. by a
    /// storage migration or recovery flow), causing duplicate detection to
    /// look in the wrong directory and every import to appear unique.
    private var libraryURL: URL { StorageManager.shared.storyCastLibraryURL }

    private init() {}

    func isDuplicate(
        title: String,
        duration: Double,
        author: String?,
        fileSize: Int64?,
        stagedFileURL: URL,
        in context: ModelContext
    ) async throws -> Bool {
        let existingBooks: [Book]
        do {
            existingBooks = try context.fetch(FetchDescriptor<Book>())
        } catch {
            AppLogger.importService.error("Failed to fetch books for duplicate detection: \(error.localizedDescription, privacy: .private)")
            return false
        }

        let importHashTask = Task.detached(priority: .utility) {
            try Self.sha256Hex(of: stagedFileURL)
        }
        guard let importHash = try await awaitHashTask(importHashTask) else {
            AppLogger.importService.warning("Skipped hash-based duplicate detection because the staged file could not be read")
            return false
        }

        let candidateURLs = existingBooks.compactMap { existingBook -> URL? in
            guard !existingBook.isRemote else { return nil }

            guard let existingFileURL = Self.managedLibraryFileURL(
                for: existingBook.localFileName,
                libraryURL: libraryURL
            ) else {
                return nil
            }
            guard Self.isRegularFile(at: existingFileURL) else {
                return nil
            }

            if let fileSize {
                let existingFileSize = Self.fileSizeInBytes(at: existingFileURL)
                if let existingFileSize, fileSize != existingFileSize {
                    return nil
                }
            }
            return existingFileURL
        }

        guard !candidateURLs.isEmpty else { return false }

        let comparisonTask = Task.detached(priority: .utility) {
            for candidateURL in candidateURLs {
                try Task.checkCancellation()
                if try Self.sha256Hex(of: candidateURL) == importHash {
                    return true
                }
            }
            return false
        }
        return try await awaitComparisonTask(comparisonTask)
    }

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

    private nonisolated static func sha256Hex(of url: URL) throws -> String? {
        do {
            guard isRegularFile(at: url) else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 1_048_576)
                guard let data, !data.isEmpty else { break }
                hasher.update(data: data)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private nonisolated static func isRegularFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func awaitHashTask(_ task: Task<String?, Error>) async throws -> String? {
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func awaitComparisonTask(_ task: Task<Bool, Error>) async throws -> Bool {
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private nonisolated static func managedLibraryFileURL(for fileName: String, libraryURL: URL) -> URL? {
        guard StorageCleanupCoordinator.isSafeRelativePath(fileName) else { return nil }
        let root = libraryURL.standardizedFileURL
        let fileURL = root.appendingPathComponent(fileName).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == root else { return nil }
        return fileURL
    }
}
