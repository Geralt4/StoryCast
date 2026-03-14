import SwiftData
import AVFoundation
import Foundation
import Combine
import os

@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

    private init() {}

    @Published var isImporting = false
    @Published var totalFiles: Int = 0
    @Published var completedFiles: Int = 0
    @Published var currentFileName: String = ""
    @Published var importErrors: [ImportError] = []
    @Published var skippedDuplicateFileNames: [String] = []
    @Published var currentPhase: ImportPhase = .idle
    @Published var downloadProgress: Double = 0.0
    @Published var failedImports: [FailedImport] = []

    private var currentImportTask: Task<Void, Error>?
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var importWasCancelled = false

#if DEBUG
    var debugStageDelayNanoseconds: UInt64?
    private(set) var debugDidStageFile = false
#endif

    func importFiles(urls: [URL], container: ModelContainer) async {
        await importFilesToFolder(urls: urls, folderId: nil, container: container)
    }

    func importFilesToFolder(urls: [URL], folderId: UUID?, container: ModelContainer) async {
        importWasCancelled = false
        currentImportTask?.cancel()

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            isImporting = true
            totalFiles = urls.count
            completedFiles = 0
            currentFileName = ""
            importErrors = []
            skippedDuplicateFileNames = []

            defer {
                isImporting = false
                if Task.isCancelled {
                    currentPhase = .idle
                    downloadProgress = 0.0
                }
            }

            for url in urls {
                guard !Task.isCancelled else { break }
                currentFileName = url.lastPathComponent

                do {
                    let didImport = try await performImport(url: url, folderId: folderId, container: container)
                    guard !Task.isCancelled else { break }

                    if didImport {
                        completedFiles += 1
                    } else {
                        skippedDuplicateFileNames.append(url.lastPathComponent)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    importErrors.append(ImportError(fileName: url.lastPathComponent, error: error))
                    AppLogger.importService.error("Import failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        currentImportTask = task
        _ = try? await task.value

        if currentImportTask == task {
            currentImportTask = nil
        }

        if !importWasCancelled {
            announceImportSummary()
        }
    }

    func cancelImport() {
        importWasCancelled = true
        currentImportTask?.cancel()
        currentImportTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        isImporting = false
        currentPhase = .idle
        downloadProgress = 0.0
        currentFileName = ""
        AccessibilityNotifications.announce("Import canceled")
    }

    func importFile(url: URL, container: ModelContainer) async throws {
        importWasCancelled = false
        currentImportTask?.cancel()

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            isImporting = true
            totalFiles = 1
            completedFiles = 0
            currentFileName = url.lastPathComponent
            importErrors = []
            skippedDuplicateFileNames = []

            defer {
                isImporting = false
                currentPhase = .idle
                downloadProgress = 0.0
            }

            let didImport = try await performImport(url: url, folderId: nil, container: container)
            guard !Task.isCancelled else { throw CancellationError() }

            if didImport {
                completedFiles = 1
                AccessibilityNotifications.announce("Imported \(url.deletingPathExtension().lastPathComponent)")
            } else {
                skippedDuplicateFileNames = [url.lastPathComponent]
                AccessibilityNotifications.announce("\(url.deletingPathExtension().lastPathComponent) is already in your library")
            }
        }

        currentImportTask = task
        defer {
            if currentImportTask == task {
                currentImportTask = nil
            }
        }

        do {
            try await task.value
        } catch {
            throw error
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

    private func performImport(
        url: URL,
        folderId: UUID?,
        container: ModelContainer,
        retryCountOnFailure: Int = 0,
        shouldScheduleAutoRetry: Bool = true
    ) async throws -> Bool {
        guard await MainActor.run(body: { SupportedFormats.isSupported(url) }) else {
            let errorType = ImportErrorType.unsupportedFormat
            recordFailure(
                for: url,
                errorType: errorType,
                retryCount: retryCountOnFailure,
                container: container,
                shouldScheduleAutoRetry: false
            )
            throw ImportServiceError.unsupportedFormat(errorType.userMessage)
        }

        currentPhase = .downloading
        downloadProgress = 0.0

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        if !didAccessSecurityScope {
            AppLogger.importService.warning("startAccessingSecurityScopedResource returned false for \(url.lastPathComponent, privacy: .private(mask: .hash)); file may already be in sandbox — proceeding.")
        }
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var stagedArtifactURLs: [URL] = []
        var finalAudioURLForCleanup: URL?
        var stagedCoverArtFileName: String?
        var didPersistImport = false

        defer {
            for stagedURL in stagedArtifactURLs {
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                } catch {
                    AppLogger.importService.warning("Failed to clean up staged file: \(error.localizedDescription, privacy: .private)")
                }
            }

            if !didPersistImport, let finalAudioURLForCleanup {
                do {
                    try FileManager.default.removeItem(at: finalAudioURLForCleanup)
                } catch {
                    AppLogger.importService.warning("Failed to clean up audio file after failed import: \(error.localizedDescription, privacy: .private)")
                }
            }

            if let stagedCoverArtFileName {
                Task {
                    await StorageManager.shared.deleteCoverArt(fileName: stagedCoverArtFileName)
                }
            }
        }

        do {
            try await accessCloudFile(at: url)
            try Task.checkCancellation()

            currentPhase = .processing

#if DEBUG
            debugDidStageFile = false
#endif

            let stagedAudioURL = try makeStagingURL(for: url)
            try await copyFileToStagingURL(at: url, destinationURL: stagedAudioURL)
            stagedArtifactURLs.append(stagedAudioURL)

#if DEBUG
            debugDidStageFile = true
            if let debugStageDelayNanoseconds {
                try await Task.sleep(nanoseconds: debugStageDelayNanoseconds)
                try Task.checkCancellation()
            }
#endif

            let asset = AVURLAsset(url: stagedAudioURL)
            let duration = try await loadDuration(for: asset)
            let metadata: [AVMetadataItem]?
            do {
                metadata = try await asset.load(.commonMetadata)
            } catch {
                AppLogger.importService.debug("Could not load common metadata: \(error.localizedDescription, privacy: .private)")
                metadata = nil
            }
            let author = await Self.authorFromMetadata(metadata ?? [])
            let coverArtData = await CoverArtExtractor().extractCoverArt(from: stagedAudioURL)
            let title = url.deletingPathExtension().lastPathComponent
            let bookId = UUID()
            let storageManager = StorageManager.shared

            try Task.checkCancellation()
            try await storageManager.setupStoryCastLibraryDirectory()

            if let coverArtData {
                stagedCoverArtFileName = try await saveCoverArtIfPossible(coverArtData, for: bookId, storageManager: storageManager)
            }

            try Task.checkCancellation()

            let importedFileSize = Self.fileSizeInBytes(at: stagedAudioURL)

            let context = ModelContext(container)
            let isDuplicate = ImportDuplicateDetector.shared.isDuplicate(
                title: title,
                duration: duration,
                author: author,
                fileSize: importedFileSize,
                in: context
            )

            if isDuplicate {
                AppLogger.importService.info("Skipped duplicate import for \"\(title)\" (duration: \(String(format: "%.1f", duration))s)")
                currentPhase = .idle
                return false
            }

            try Task.checkCancellation()

            let finalURL = try await storageManager.moveStagedFileToStoryCastLibraryDirectory(from: stagedAudioURL, withName: url.lastPathComponent)
            stagedArtifactURLs.removeAll { $0 == stagedAudioURL }
            finalAudioURLForCleanup = finalURL

            let detectedChapters = try await loadDetectedChapters(from: finalURL)
            try Task.checkCancellation()

            let targetFolder = try resolveTargetFolder(folderId: folderId, in: context)
            let book = Book(
                id: bookId,
                title: title,
                author: author,
                localFileName: finalURL.lastPathComponent,
                duration: duration,
                isImported: true,
                folder: targetFolder,
                coverArtFileName: stagedCoverArtFileName
            )
            context.insert(book)

            if book.folder == nil {
                AppLogger.importService.error("Unfiled folder missing during import; book will be unassigned")
            }

            for detectedChapter in detectedChapters {
                let chapter = Chapter(
                    title: detectedChapter.title,
                    startTime: detectedChapter.startTime,
                    endTime: detectedChapter.endTime,
                    source: detectedChapter.source,
                    book: book
                )

                guard chapter.isValid else {
                    AppLogger.importService.warning("Skipping invalid chapter during import")
                    continue
                }

                context.insert(chapter)
            }

            try context.save()
            didPersistImport = true
            currentPhase = .idle
            finalAudioURLForCleanup = nil
            stagedCoverArtFileName = nil
            return true
        } catch is CancellationError {
            currentPhase = .idle
            downloadProgress = 0.0
            throw CancellationError()
        } catch {
            currentPhase = .idle
            let errorType = classifyError(error)
            recordFailure(
                for: url,
                errorType: errorType,
                retryCount: retryCountOnFailure,
                container: container,
                shouldScheduleAutoRetry: shouldScheduleAutoRetry
            )
            throw error
        }
    }

    private func loadDuration(for asset: AVURLAsset) async throws -> Double {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ImportServiceError.invalidDuration
        }
        return duration
    }

    private func loadDetectedChapters(from url: URL) async throws -> [DetectedChapter] {
        do {
            return try await MetadataChapterExtractor().extractChapters(from: url)
        } catch {
            AppLogger.importService.warning("Failed to extract chapters from \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private func saveCoverArtIfPossible(_ data: Data, for bookId: UUID, storageManager: StorageManager) async throws -> String? {
        do {
            return try await storageManager.saveCoverArt(data, for: bookId)
        } catch {
            AppLogger.importService.warning("Failed to save cover art for \(bookId.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func resolveTargetFolder(folderId: UUID?, in context: ModelContext) throws -> Folder? {
        func fetchUnfiledFolder() -> Folder? {
            var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
            unfiledFetch.fetchLimit = 1
            do {
                return try context.fetch(unfiledFetch).first
            } catch {
                AppLogger.importService.error("Failed to fetch unfiled folder: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }

        guard let folderId else {
            return fetchUnfiledFolder()
        }

        let folderFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderId })
        do {
            if let folder = try context.fetch(folderFetch).first {
                return folder
            }

            AppLogger.importService.warning("Target folder \(folderId.uuidString, privacy: .private(mask: .hash)) not found; importing as unfiled.")
            return fetchUnfiledFolder()
        } catch {
            AppLogger.importService.error("Error fetching folder \(folderId.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return fetchUnfiledFolder()
        }
    }

    private func makeStagingURL(for sourceURL: URL) throws -> URL {
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("StoryCastImportStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension
        let fileName = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        return stagingDirectory.appendingPathComponent(fileName)
    }

    private func copyFileToStagingURL(at sourceURL: URL, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var hasResumed = false

            coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: ())
                    }
                } catch {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }

            if let coordinationError, !hasResumed {
                hasResumed = true
                continuation.resume(throwing: coordinationError)
            }
        }
    }

    private func recordFailure(
        for url: URL,
        errorType: ImportErrorType,
        retryCount: Int,
        container: ModelContainer,
        shouldScheduleAutoRetry: Bool
    ) {
        let sourceKey = FailedImport.normalizedSourceKey(for: url)

        let failedImport = FailedImport(
            url: url,
            fileName: url.lastPathComponent,
            errorType: errorType,
            errorMessage: errorType.userMessage,
            retryCount: retryCount
        )

        upsertFailedImport(failedImport)

        if shouldScheduleAutoRetry && failedImport.canAutoRetry {
            scheduleAutoRetry(for: failedImport, container: container)
        } else {
            retryTasks.removeValue(forKey: sourceKey)?.cancel()
        }
    }

    private func upsertFailedImport(_ failedImport: FailedImport) {
        if let index = failedImports.firstIndex(where: { $0.sourceKey == failedImport.sourceKey }) {
            failedImports[index] = failedImport
        } else {
            failedImports.append(failedImport)
        }
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

    private func accessCloudFile(at url: URL) async throws {
        currentPhase = .downloading
        downloadProgress = 0.0

        _ = try await ImportCloudHandler.shared.accessCloudFile(at: url) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        try Task.checkCancellation()
    }

    private nonisolated static func authorFromMetadata(_ metadata: [AVMetadataItem]) async -> String? {
        let candidateKeys = Set(["author", "artist", "albumartist", "creator"])
        for item in metadata {
            guard let key = item.commonKey?.rawValue.lowercased(), candidateKeys.contains(key) else { continue }
            do {
                if let value = try await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            } catch {
                AppLogger.importService.debug("Could not load stringValue for metadata key \(key): \(error.localizedDescription, privacy: .private)")
            }
            do {
                if let value = try await item.load(.value), let stringValue = value as? String {
                    let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            } catch {
                AppLogger.importService.debug("Could not load raw value for metadata key \(key): \(error.localizedDescription, privacy: .private)")
            }
        }
        return nil
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
        retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        let previousRetryCount = failedImport.retryCount
        failedImports.removeAll { $0.sourceKey == failedImport.sourceKey }

        await performRetryImport(url: failedImport.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
    }

    func retryAllFailed(container: ModelContainer) async {
        let retryableImports = failedImports.filter { $0.errorType.isTransient }
        let retryCounts = Dictionary(uniqueKeysWithValues: retryableImports.map { ($0.sourceKey, $0.retryCount) })

        for failedImport in retryableImports {
            retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        }

        failedImports.removeAll { $0.errorType.isTransient }

        for failedImport in retryableImports {
            let previousRetryCount = retryCounts[failedImport.sourceKey] ?? 0
            await performRetryImport(url: failedImport.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
        }
    }

    func dismissFailedImport(_ failedImport: FailedImport) {
        retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        failedImports.removeAll { $0.sourceKey == failedImport.sourceKey }
    }

    private func performRetryImport(url: URL, folderId: UUID?, container: ModelContainer, previousRetryCount: Int) async {
        do {
            _ = try await performImport(
                url: url,
                folderId: folderId,
                container: container,
                retryCountOnFailure: previousRetryCount + 1,
                shouldScheduleAutoRetry: true
            )
        } catch is CancellationError {
            return
        } catch {
            AppLogger.importService.error("Retry import failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func scheduleAutoRetry(for failedImport: FailedImport, container: ModelContainer) {
        let sourceKey = failedImport.sourceKey
        retryTasks.removeValue(forKey: sourceKey)?.cancel()

        guard failedImport.canAutoRetry else { return }

        let attemptNumber = failedImport.retryCount + 1
        let delay = pow(2.0, Double(failedImport.retryCount))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch is CancellationError {
                retryTasks.removeValue(forKey: sourceKey)
                return
            } catch {
                AppLogger.importService.warning("Unexpected error during auto-retry delay: \(error.localizedDescription, privacy: .private)")
                retryTasks.removeValue(forKey: sourceKey)
                return
            }

            guard !Task.isCancelled,
                  let currentFailure = failedImports.first(where: { $0.sourceKey == sourceKey }),
                  currentFailure.retryCount + 1 == attemptNumber else {
                retryTasks.removeValue(forKey: sourceKey)
                return
            }

            retryTasks.removeValue(forKey: sourceKey)
            await retryImport(currentFailure, container: container)
        }

        retryTasks[sourceKey] = task
    }
}

struct ImportError: Identifiable {
    let id = UUID()
    let fileName: String
    let error: Error
}

#if DEBUG
extension ImportService {
    var debugRetryTaskCount: Int { retryTasks.count }

    func debugRegisterRetryTask(_ task: Task<Void, Never>, for sourceKey: String) {
        retryTasks[sourceKey]?.cancel()
        retryTasks[sourceKey] = task
    }

    func debugResetState() {
        currentImportTask?.cancel()
        currentImportTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        importWasCancelled = false
        isImporting = false
        totalFiles = 0
        completedFiles = 0
        currentFileName = ""
        importErrors = []
        skippedDuplicateFileNames = []
        currentPhase = .idle
        downloadProgress = 0.0
        failedImports = []
        debugStageDelayNanoseconds = nil
        debugDidStageFile = false
    }
}
#endif
