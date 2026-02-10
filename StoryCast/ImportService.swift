import SwiftData
import AVFoundation
import Foundation
import Combine
import os

enum ImportPhase: String {
    case idle = "Idle"
    case downloading = "Downloading"
    case processing = "Processing"
}

enum ImportErrorType {
    case networkUnavailable
    case networkTimeout
    case connectionLost
    case fileAccessDenied
    case fileNotFound
    case unsupportedFormat
    case drmProtected
    case unknown

    var isTransient: Bool {
        switch self {
        case .networkTimeout, .connectionLost:
            return true
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .networkUnavailable:
            return "No internet connection. Check your network and try again."
        case .networkTimeout:
            return "Download timed out. The file may be too large or the connection too slow."
        case .connectionLost:
            return "Connection lost during download. Please try again."
        case .fileAccessDenied:
            return "Cannot access this file. You may need to re-authenticate with the cloud service."
        case .fileNotFound:
            return "File not found. It may have been moved or deleted."
        case .unsupportedFormat:
            return "This file format is not supported."
        case .drmProtected:
            return "This book is DRM-protected and cannot be imported. Try exporting it from your audiobook service first."
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}

struct FailedImport: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let errorType: ImportErrorType
    let errorMessage: String
    var retryCount: Int = 0
    let maxRetries: Int = ImportDefaults.maxRetries
    
    var canAutoRetry: Bool {
        errorType.isTransient && retryCount < maxRetries
    }
}

@MainActor
class ImportService: ObservableObject {
    static let shared = ImportService()

    private init() {}
    @Published var isImporting = false

    // Progress tracking
    @Published var totalFiles: Int = 0
    @Published var completedFiles: Int = 0
    @Published var currentFileName: String = ""
    @Published var importErrors: [ImportError] = []
    @Published var skippedDuplicateFileNames: [String] = []

    // Phase tracking
    @Published var currentPhase: ImportPhase = .idle
    @Published var downloadProgress: Double = 0.0

    // Retry support
    @Published var failedImports: [FailedImport] = []

    // Cancellation support
    private var currentImportTask: Task<Void, Never>?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var importWasCancelled = false

    func importFiles(urls: [URL], container: ModelContainer) async {
        await importFilesToFolder(urls: urls, folderId: nil, container: container)
    }

    func importFilesToFolder(urls: [URL], folderId: UUID?, container: ModelContainer) async {
        importWasCancelled = false
        currentImportTask?.cancel()
        currentImportTask = Task {
            isImporting = true
            totalFiles = urls.count
            completedFiles = 0
            importErrors = []
            skippedDuplicateFileNames = []

            defer {
                isImporting = false
            }

            for url in urls {
                guard !Task.isCancelled else { break }
                currentFileName = url.lastPathComponent

                do {
                    let didImport = try await performImport(url: url, folderId: folderId, container: container)
                    if didImport {
                        completedFiles += 1
                    } else {
                        skippedDuplicateFileNames.append(url.lastPathComponent)
                    }
                } catch {
                    importErrors.append(ImportError(fileName: url.lastPathComponent, error: error))
                    AppLogger.importService.error("Import failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }

                guard !Task.isCancelled else { break }
            }
        }
        await currentImportTask?.value
        currentImportTask = nil
        if !importWasCancelled {
            announceImportSummary()
        }
    }

    func cancelImport() {
        importWasCancelled = true
        currentImportTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        isImporting = false
        currentPhase = .idle
        downloadProgress = 0.0
        AccessibilityNotifications.announce("Import canceled")
    }

    func importFile(url: URL, container: ModelContainer) async throws {
        isImporting = true
        defer {
            isImporting = false
        }
        let didImport = try await performImport(url: url, folderId: nil, container: container)
        if didImport {
            AccessibilityNotifications.announce("Imported \(url.deletingPathExtension().lastPathComponent)")
        } else {
            AccessibilityNotifications.announce("\(url.deletingPathExtension().lastPathComponent) is already in your library")
        }
    }

    private func announceImportSummary() {
        guard totalFiles > 0 else { return }

        let failedCount = importErrors.count
        let skippedCount = skippedDuplicateFileNames.count
        if completedFiles == totalFiles && failedCount == 0 && skippedCount == 0 {
            let suffix = completedFiles == 1 ? "file" : "files"
            AccessibilityNotifications.announce("Imported \(completedFiles) \(suffix)")
            return
        }

        if failedCount == 0 && skippedCount > 0 {
            if completedFiles > 0 {
                let importedSuffix = completedFiles == 1 ? "file" : "files"
                let skippedSuffix = skippedCount == 1 ? "file" : "files"
                AccessibilityNotifications.announce("Imported \(completedFiles) \(importedSuffix). \(skippedCount) \(skippedSuffix) already in library")
            } else {
                let skippedSuffix = skippedCount == 1 ? "file" : "files"
                AccessibilityNotifications.announce("No new files imported. \(skippedCount) \(skippedSuffix) already in library")
            }
            return
        }

        if completedFiles > 0 && failedCount > 0 {
            let skippedSuffix = skippedCount == 1 ? "file" : "files"
            if skippedCount > 0 {
                AccessibilityNotifications.announce("Imported \(completedFiles) of \(totalFiles) files. \(failedCount) failed. \(skippedCount) \(skippedSuffix) already in library")
            } else {
                AccessibilityNotifications.announce("Imported \(completedFiles) of \(totalFiles) files. \(failedCount) failed")
            }
            return
        }

        if failedCount > 0 {
            let suffix = failedCount == 1 ? "file" : "files"
            let skippedSuffix = skippedCount == 1 ? "file" : "files"
            if skippedCount > 0 {
                AccessibilityNotifications.announce("Import failed for \(failedCount) \(suffix). \(skippedCount) \(skippedSuffix) already in library")
            } else {
                AccessibilityNotifications.announce("Import failed for \(failedCount) \(suffix)")
            }
        }
    }

    private func performImport(url: URL, folderId: UUID?, container: ModelContainer) async throws -> Bool {
        // Check if format is supported before processing
        guard SupportedFormats.isSupported(url) else {
            let errorType = ImportErrorType.unsupportedFormat
            let error = NSError(domain: "ImportError", code: 1, userInfo: [NSLocalizedDescriptionKey: errorType.userMessage])
            let failedImport = FailedImport(
                url: url,
                fileName: url.lastPathComponent,
                errorType: errorType,
                errorMessage: errorType.userMessage
            )
            failedImports.append(failedImport)
            throw error
        }

        currentPhase = .downloading
        downloadProgress = 0.0

        var resourceAccessError: Error?
        let fileAccessed: Bool = await {
            do {
                _ = try await accessCloudFile(at: url)
                return true
            } catch {
                resourceAccessError = error
                return false
            }
        }()

        if !fileAccessed, let error = resourceAccessError {
            let errorType = classifyError(error)
            let failedImport = FailedImport(
                url: url,
                fileName: url.lastPathComponent,
                errorType: errorType,
                errorMessage: errorType.userMessage
            )

            failedImports.append(failedImport)

            if failedImport.canAutoRetry {
                await scheduleAutoRetry(for: failedImport, container: container)
            }

            throw error
        }

        // startAccessingSecurityScopedResource() returns false for files already
        // inside the app sandbox (e.g., discovered by scanAndImportExistingFiles).
        // This is expected — proceed anyway; only call stop if we actually acquired access.
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        if !didAccessSecurityScope {
            AppLogger.importService.warning("startAccessingSecurityScopedResource returned false for \(url.lastPathComponent, privacy: .private(mask: .hash)); file may already be in sandbox — proceeding.")
        }
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        currentPhase = .processing

        do {
            let (duration, coverArtData, author) = try await Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else {
                    throw NSError(domain: "ImportError", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not determine audio duration"])
                }
                let coverArtData = await CoverArtExtractor().extractCoverArt(from: url)
                let metadata = try? await asset.load(.commonMetadata)
                let author = await Self.authorFromMetadata(metadata ?? [])
                return (duration, coverArtData, author)
            }.value

            let title = url.deletingPathExtension().lastPathComponent
            let storageManager = StorageManager.shared
            try await Task.detached(priority: .utility) {
                try await storageManager.setupStoryCastLibraryDirectory()
            }.value

            let bookId = UUID()
            var coverArtFileName: String?
            if let coverArtData = coverArtData {
                coverArtFileName = await Task.detached(priority: .utility) {
                    do {
                        return try await storageManager.saveCoverArt(coverArtData, for: bookId)
                    } catch {
                        AppLogger.importService.warning("Failed to save cover art for \(bookId.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                        return nil
                    }
                }.value
            }

            let localURL = try await Task.detached(priority: .utility) {
                try await storageManager.copyFileToStoryCastLibraryDirectory(from: url, withName: url.lastPathComponent)
            }.value

            let importedFileSize = await Task.detached(priority: .utility) {
                Self.fileSizeInBytes(at: localURL)
            }.value

            currentPhase = .idle

            let extractor = MetadataChapterExtractor()
            let detectedChaptersTask = Task.detached(priority: .utility) {
                do {
                    return try await extractor.extractChapters(from: localURL)
                } catch {
                    AppLogger.importService.warning("Failed to extract chapters from \(localURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                    return []
                }
            }
            let detectedChapters = await detectedChaptersTask.value

            let chaptersToInsert = detectedChapters
            let targetFolderId = folderId
            let importDuration = duration
            let importNormalizedTitle = Self.normalizedDuplicateToken(title)
            let importNormalizedAuthor = Self.normalizedDuplicateToken(author)
            let importedFileSizeBytes = importedFileSize
            
            enum SaveResult {
                case success
                case duplicate
                case error(Error)
            }
            
            let saveResult = await Task.detached(priority: .utility) { () -> SaveResult in
                let context = ModelContext(container)
                
                // Duplicate check:
                // - normalized title and duration must match
                // - if both sides have author metadata, author must match
                // - otherwise, fallback to exact file size match
                let existingBooks = (try? context.fetch(FetchDescriptor<Book>())) ?? []
                let libraryURL = StorageManager.shared.storyCastLibraryURL
                let isDuplicate = existingBooks.contains { existingBook in
                    guard Self.normalizedDuplicateToken(existingBook.title) == importNormalizedTitle else { return false }
                    guard abs(existingBook.duration - importDuration) < 1.0 else { return false }

                    let existingFileURL = libraryURL.appendingPathComponent(existingBook.localFileName)
                    guard FileManager.default.fileExists(atPath: existingFileURL.path) else {
                        return false
                    }

                    let existingFileSize = Self.fileSizeInBytes(at: existingFileURL)
                    let existingAuthor = Self.normalizedDuplicateToken(existingBook.author)
                    if let importedFileSizeBytes,
                       let existingFileSize,
                       importedFileSizeBytes != existingFileSize {
                        return false
                    }

                    if !importNormalizedAuthor.isEmpty && !existingAuthor.isEmpty {
                        return existingAuthor == importNormalizedAuthor
                    }

                    return true
                }
                if isDuplicate {
                    return .duplicate
                }
                
                let book = Book(
                    id: bookId,
                    title: title,
                    author: author,
                    localFileName: localURL.lastPathComponent,
                    duration: duration,
                    isImported: true,
                    folder: nil,
                    coverArtFileName: coverArtFileName
                )
                context.insert(book)

                func fetchUnfiledFolder() -> Folder? {
                    var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
                    unfiledFetch.fetchLimit = 1
                    return try? context.fetch(unfiledFetch).first
                }

                if let targetFolderId {
                    let folderFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == targetFolderId })
                    do {
                        if let folder = try context.fetch(folderFetch).first {
                            book.folder = folder
                        } else {
                            AppLogger.importService.warning("Target folder \(targetFolderId.uuidString, privacy: .private(mask: .hash)) not found; importing as unfiled.")
                            book.folder = fetchUnfiledFolder()
                        }
                    } catch {
                        AppLogger.importService.error("Error fetching folder \(targetFolderId.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                        book.folder = fetchUnfiledFolder()
                    }
                } else {
                    book.folder = fetchUnfiledFolder()
                }

                if book.folder == nil {
                    AppLogger.importService.error("Unfiled folder missing during import; book will be unassigned")
                }

                if !chaptersToInsert.isEmpty {
                    for detChapter in chaptersToInsert {
                        let chapter = Chapter(
                            title: detChapter.title,
                            startTime: detChapter.startTime,
                            endTime: detChapter.endTime,
                            source: detChapter.source,
                            book: book
                        )
                        guard chapter.isValid else {
                            AppLogger.importService.warning("Skipping invalid chapter during import")
                            continue
                        }
                        context.insert(chapter)
                    }
                }

                do {
                    try context.save()
                } catch {
                    return .error(error)
                }

                return .success
            }.value

            switch saveResult {
            case .success:
                return true
            case .duplicate:
                AppLogger.importService.info("Skipped duplicate import for \"\(title)\" (duration: \(String(format: "%.1f", duration))s)")
                // Clean up the copied file and cover art since we're not keeping this duplicate
                try? FileManager.default.removeItem(at: localURL)
                if let coverArtFileName {
                    await storageManager.deleteCoverArt(fileName: coverArtFileName)
                }
                return false
            case .error(let saveError):
                AppLogger.importService.error("Error saving imported book data: \(saveError.localizedDescription, privacy: .private)")
                
                // Clean up orphaned files since the SwiftData save failed
                try? FileManager.default.removeItem(at: localURL)
                if let coverArtFileName {
                    await storageManager.deleteCoverArt(fileName: coverArtFileName)
                }
                throw saveError
            }
        } catch {
            let errorType = classifyError(error)
            let failedImport = FailedImport(
                url: url,
                fileName: url.lastPathComponent,
                errorType: errorType,
                errorMessage: errorType.userMessage
            )

            failedImports.append(failedImport)

            if failedImport.canAutoRetry {
                await scheduleAutoRetry(for: failedImport, container: container)
            }

            throw error
        }
    }

    private nonisolated static func authorFromMetadata(_ metadata: [AVMetadataItem]) async -> String? {
        let candidateKeys = Set(["author", "artist", "albumartist", "creator"])
        for item in metadata {
            guard let key = item.commonKey?.rawValue.lowercased(), candidateKeys.contains(key) else { continue }
            if let value = try? await item.load(.stringValue) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            if let value = try? await item.load(.value), let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
    
    private nonisolated func classifyError(_ error: Error) -> ImportErrorType {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return .networkUnavailable
            case NSURLErrorTimedOut:
                return .networkTimeout
            case NSURLErrorNetworkConnectionLost:
                return .connectionLost
            case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable:
                return .fileNotFound
            case NSURLErrorNoPermissionsToReadFile:
                return .fileAccessDenied
            default:
                break
            }
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError:
                return .fileNotFound
            case NSFileReadNoPermissionError:
                return .fileAccessDenied
            default:
                break
            }
        }

        if nsError.domain == AVFoundationErrorDomain {
            switch nsError.code {
            case -16840, -16841, -16842, -16843:
                return .drmProtected
            default:
                break
            }
        }

        if nsError.code == 260 {
            return .fileNotFound
        }

        return .unknown
    }
    
    private func accessCloudFile(at url: URL) async throws -> Bool {
        currentPhase = .downloading
        downloadProgress = 0.0

        // Check if this is an iCloud file that needs downloading
        let resourceValues = try await loadCloudResourceValues(for: url)

        if !resourceValues.isCurrent {
            // File needs downloading - trigger download and monitor progress
            return try await downloadCloudFile(at: url)
        }

        // File is local or already downloaded, use file coordinator
        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)

            // Use a background queue to avoid blocking the main thread
            let backgroundQueue = OperationQueue()
            backgroundQueue.qualityOfService = .utility
            coordinator.coordinate(with: [intent], queue: backgroundQueue) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    private func downloadCloudFile(at url: URL) async throws -> Bool {
        // Start the download
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // For now, use a simpler approach with polling since NSMetadataQuery
        // has Sendable issues with Swift concurrency
        return try await monitorDownloadProgress(url: url)
    }

    private func monitorDownloadProgress(url: URL) async throws -> Bool {
        let startTime = Date()
        let timeout: TimeInterval = ImportDefaults.downloadTimeout

        while Date().timeIntervalSince(startTime) < timeout {
            try await Task.sleep(nanoseconds: TimerDefaults.progressPollingNanoseconds)

            let resourceValues = try await loadCloudResourceValues(for: url)

            if resourceValues.isCurrent {
                // Download complete
                return true
            }

            if let percentDownloaded = resourceValues.percentDownloaded {
                let progress = percentDownloaded / 100.0
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress
                }
            }

            // Check for cancellation
            try Task.checkCancellation()
        }

        throw NSError(domain: "ImportError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download timed out"])
    }

    private func loadCloudResourceValues(for url: URL) async throws -> (isCurrent: Bool, percentDownloaded: Double?) {
        try await Task.detached(priority: .utility) {
            // NOTE: "ubiquitousItemPercentDownloadedKey" is not a public URLResourceKey constant.
            // We use the string literal because Apple does not expose this key in the public SDK,
            // but it has been stable across iOS releases. If it breaks in a future iOS version,
            // download progress reporting will degrade gracefully (percentDownloaded will be nil).
            let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, URLResourceKey("ubiquitousItemPercentDownloadedKey")])
            let status = resourceValues.ubiquitousItemDownloadingStatus
            let isCurrent = status == nil || status == .current
            let percentDownloaded = (resourceValues.allValues[URLResourceKey("ubiquitousItemPercentDownloadedKey")] as? NSNumber)?.doubleValue
            return (isCurrent, percentDownloaded)
        }.value
    }

    private nonisolated static func normalizedDuplicateToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
    
    func retryImport(_ failedImport: FailedImport, container: ModelContainer) async {
        guard let index = failedImports.firstIndex(where: { $0.id == failedImport.id }) else { return }

        let previousRetryCount = failedImports[index].retryCount
        retryTasks.removeValue(forKey: failedImport.id)?.cancel()
        _ = failedImports.remove(at: index)
        
        await performRetryImport(url: failedImport.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
    }
    
    func retryAllFailed(container: ModelContainer) async {
        let toRetry = failedImports.filter { $0.errorType.isTransient }

        for failedImport in toRetry {
            retryTasks.removeValue(forKey: failedImport.id)?.cancel()
        }
        let retryCounts = Dictionary(toRetry.map { ($0.url, $0.retryCount) }, uniquingKeysWith: max)
        failedImports.removeAll { $0.errorType.isTransient }
        
        for item in toRetry {
            let previousRetryCount = retryCounts[item.url] ?? 0
            await performRetryImport(url: item.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
        }
    }
    
    func dismissFailedImport(_ failedImport: FailedImport) {
        retryTasks.removeValue(forKey: failedImport.id)?.cancel()
        failedImports.removeAll { $0.id == failedImport.id }
    }

    /// Retries a single import, carrying forward the previous retry count so that
    /// any new FailedImport created by performImport starts at the correct count
    /// instead of resetting to 0 (which would cause an infinite retry loop).
    private func performRetryImport(url: URL, folderId: UUID?, container: ModelContainer, previousRetryCount: Int) async {
        let countBefore = failedImports.count
        do {
            _ = try await performImport(url: url, folderId: folderId, container: container)
        } catch {
            // performImport already appended a FailedImport — carry forward the retry count + 1
            if failedImports.count > countBefore {
                let newIndex = failedImports.count - 1
                failedImports[newIndex].retryCount = previousRetryCount + 1
            }
        }
    }
    
    private func scheduleAutoRetry(for failedImport: FailedImport, container: ModelContainer) async {
        guard failedImport.canAutoRetry else { return }

        let delay = pow(2.0, Double(failedImport.retryCount))

        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                self.retryTasks.removeValue(forKey: failedImport.id)
                return
            }
            guard !Task.isCancelled else { return }

            if let index = self.failedImports.firstIndex(where: { $0.id == failedImport.id }) {
                self.failedImports[index].retryCount += 1
            }

            if let retryItem = self.failedImports.first(where: { $0.id == failedImport.id }) {
                await self.retryImport(retryItem, container: container)
            }

            self.retryTasks.removeValue(forKey: failedImport.id)
        }
        retryTasks[failedImport.id] = task
    }
}

struct ImportError: Identifiable {
    let id = UUID()
    let fileName: String
    let error: Error
}
