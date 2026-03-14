import SwiftData
import AVFoundation
import Foundation
import Combine
import os

@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

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
    private var importWasCancelled = false
    private(set) var retryManager: ImportRetryManager!

#if DEBUG
    var debugStageDelayNanoseconds: UInt64?
    private(set) var debugDidStageFile = false
#endif

    private init() {
        self.retryManager = ImportRetryManager(
            performImport: { [weak self] url, folderId, container, retryCount in
                guard let self else { return false }
                return try await self.performImport(url: url, folderId: folderId, container: container, retryCountOnFailure: retryCount, shouldScheduleAutoRetry: true)
            },
            getFailedImports: { [weak self] in self?.failedImports ?? [] },
            updateFailedImports: { [weak self] in self?.failedImports = $0 }
        )
    }

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
        retryManager.cancelAllRetryTasks()
        isImporting = false
        currentPhase = .idle
        downloadProgress = 0.0
        currentFileName = ""
        AccessibilityNotifications.announce("Import canceled")
    }

    func importFile(url: URL, container: ModelContainer) async throws {
        await importFilesToFolder(urls: [url], folderId: nil, container: container)

        if let error = importErrors.first {
            throw error.error
        }

        if completedFiles == 1 {
            AccessibilityNotifications.announce("Imported \(url.deletingPathExtension().lastPathComponent)")
        } else if !skippedDuplicateFileNames.isEmpty {
            AccessibilityNotifications.announce("\(url.deletingPathExtension().lastPathComponent) is already in your library")
        }
    }

    private func announceImportSummary() {
        guard totalFiles > 0 else { return }
        let message = Self.buildImportSummary(
            completed: completedFiles,
            total: totalFiles,
            failed: importErrors.count,
            skipped: skippedDuplicateFileNames.count
        )
        AccessibilityNotifications.announce(message)
    }

    private nonisolated static func buildImportSummary(
        completed: Int,
        total: Int,
        failed: Int,
        skipped: Int
    ) -> String {
        func pluralize(_ count: Int, singular: String) -> String {
            count == 1 ? singular : singular + "s"
        }

        let allSucceeded = completed == total && failed == 0 && skipped == 0
        let hasSkipped = skipped > 0
        let hasFailed = failed > 0
        let hasCompleted = completed > 0

        if allSucceeded {
            return "Imported \(completed) \(pluralize(completed, singular: "file"))"
        }

        if !hasFailed && hasSkipped {
            if hasCompleted {
                return "Imported \(completed) \(pluralize(completed, singular: "file")). \(skipped) \(pluralize(skipped, singular: "file")) already in library"
            }
            return "No new files imported. \(skipped) \(pluralize(skipped, singular: "file")) already in library"
        }

        if hasCompleted && hasFailed {
            var parts = ["Imported \(completed) of \(total) files", "\(failed) failed"]
            if hasSkipped {
                parts.append("\(skipped) \(pluralize(skipped, singular: "file")) already in library")
            }
            return parts.joined(separator: ". ")
        }

        if hasFailed {
            var parts = ["Import failed for \(failed) \(pluralize(failed, singular: "file"))"]
            if hasSkipped {
                parts.append("\(skipped) \(pluralize(skipped, singular: "file")) already in library")
            }
            return parts.joined(separator: ". ")
        }

        return ""
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
            recordFailure(for: url, errorType: errorType, retryCount: retryCountOnFailure, container: container, shouldScheduleAutoRetry: false)
            throw ImportServiceError.unsupportedFormat(errorType.userMessage)
        }

        currentPhase = .downloading
        downloadProgress = 0.0

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        if !didAccessSecurityScope {
            AppLogger.importService.warning("startAccessingSecurityScopedResource returned false for \(url.lastPathComponent, privacy: .private(mask: .hash)); file may already be in sandbox — proceeding.")
        }
        defer {
            if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        var stagedArtifactURLs: [URL] = []
        var finalAudioURLForCleanup: URL?
        var stagedCoverArtFileName: String?
        var didPersistImport = false

        defer {
            cleanupStagedArtifacts(stagedArtifactURLs, finalAudioURL: finalAudioURLForCleanup, didPersist: didPersistImport, coverArtFileName: stagedCoverArtFileName)
        }

        do {
            try await accessCloudFile(at: url)
            try Task.checkCancellation()

            currentPhase = .processing

#if DEBUG
            debugDidStageFile = false
#endif

            let stagedAudioURL = try FileStagingHelper.makeStagingURL(for: url)
            try await FileStagingHelper.copyFileToStagingURL(at: url, destinationURL: stagedAudioURL)
            stagedArtifactURLs.append(stagedAudioURL)

#if DEBUG
            debugDidStageFile = true
            if let debugStageDelayNanoseconds {
                try await Task.sleep(nanoseconds: debugStageDelayNanoseconds)
                try Task.checkCancellation()
            }
#endif

            let metadata = try await extractMetadata(from: stagedAudioURL, originalURL: url)
            try Task.checkCancellation()
            try await StorageManager.shared.setupStoryCastLibraryDirectory()

            if let coverArtData = metadata.coverArtData {
                stagedCoverArtFileName = try await saveCoverArtIfPossible(coverArtData, for: metadata.bookId, storageManager: StorageManager.shared)
            }

            try Task.checkCancellation()

            let context = ModelContext(container)
            if try checkForDuplicate(title: metadata.title, duration: metadata.duration, author: metadata.author, fileSize: metadata.fileSize, in: context) {
                AppLogger.importService.info("Skipped duplicate import for \"\(metadata.title)\" (duration: \(String(format: "%.1f", metadata.duration))s)")
                currentPhase = .idle
                return false
            }

            try Task.checkCancellation()

            let finalURL = try await StorageManager.shared.moveStagedFileToStoryCastLibraryDirectory(from: stagedAudioURL, withName: url.lastPathComponent)
            stagedArtifactURLs.removeAll { $0 == stagedAudioURL }
            finalAudioURLForCleanup = finalURL

            let detectedChapters = try await loadDetectedChapters(from: finalURL)
            try Task.checkCancellation()

            try persistBook(
                bookId: metadata.bookId,
                title: metadata.title,
                author: metadata.author,
                duration: metadata.duration,
                localFileName: finalURL.lastPathComponent,
                coverArtFileName: stagedCoverArtFileName,
                detectedChapters: detectedChapters,
                folderId: folderId,
                in: context
            )

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
            let errorType = ImportErrorType(classifying: error)
            recordFailure(for: url, errorType: errorType, retryCount: retryCountOnFailure, container: container, shouldScheduleAutoRetry: shouldScheduleAutoRetry)
            throw error
        }
    }

    private func cleanupStagedArtifacts(_ stagedURLs: [URL], finalAudioURL: URL?, didPersist: Bool, coverArtFileName: String?) {
        for url in stagedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        if !didPersist, let finalAudioURL {
            try? FileManager.default.removeItem(at: finalAudioURL)
        }
        if let coverArtFileName {
            Task { await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName) }
        }
    }

    private struct ExtractedMetadata {
        let bookId: UUID
        let title: String
        let author: String?
        let duration: Double
        let coverArtData: Data?
        let fileSize: Int64?
    }

    private func extractMetadata(from stagedURL: URL, originalURL: URL) async throws -> ExtractedMetadata {
        let asset = AVURLAsset(url: stagedURL)
        let duration = try await loadDuration(for: asset)
        let metadata: [AVMetadataItem]? = try? await asset.load(.commonMetadata)
        let author = await AudioMetadataUtils.author(from: metadata ?? [])
        let coverArtData = await CoverArtExtractor().extractCoverArt(from: stagedURL)
        let title = originalURL.deletingPathExtension().lastPathComponent
        let fileSize = AudioMetadataUtils.fileSizeInBytes(at: stagedURL)
        return ExtractedMetadata(bookId: UUID(), title: title, author: author, duration: duration, coverArtData: coverArtData, fileSize: fileSize)
    }

    private func checkForDuplicate(title: String, duration: Double, author: String?, fileSize: Int64?, in context: ModelContext) throws -> Bool {
        ImportDuplicateDetector.shared.isDuplicate(title: title, duration: duration, author: author, fileSize: fileSize, in: context)
    }

    private func persistBook(
        bookId: UUID,
        title: String,
        author: String?,
        duration: Double,
        localFileName: String,
        coverArtFileName: String?,
        detectedChapters: [DetectedChapter],
        folderId: UUID?,
        in context: ModelContext
    ) throws {
        let targetFolder = try resolveTargetFolder(folderId: folderId, in: context)
        let book = Book(
            id: bookId,
            title: title,
            author: author,
            localFileName: localFileName,
            duration: duration,
            isImported: true,
            folder: targetFolder,
            coverArtFileName: coverArtFileName
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

    private func recordFailure(
        for url: URL,
        errorType: ImportErrorType,
        retryCount: Int,
        container: ModelContainer,
        shouldScheduleAutoRetry: Bool
    ) {
        retryManager.recordFailure(for: url, errorType: errorType, retryCount: retryCount, container: container, shouldScheduleAutoRetry: shouldScheduleAutoRetry)
    }

    func retryImport(_ failedImport: FailedImport, container: ModelContainer) async {
        await retryManager.retryImport(failedImport, container: container)
    }

    func retryAllFailed(container: ModelContainer) async {
        await retryManager.retryAllFailed(container: container)
    }

    func dismissFailedImport(_ failedImport: FailedImport) {
        retryManager.dismissFailedImport(failedImport)
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
}

#if DEBUG
extension ImportService {
    var debugRetryTaskCount: Int { retryManager.retryTaskCount }

    func debugRegisterRetryTask(_ task: Task<Void, Never>, for sourceKey: String) {
        retryManager.debugRegisterRetryTask(task, for: sourceKey)
    }

    func debugResetState() {
        currentImportTask?.cancel()
        currentImportTask = nil
        retryManager.debugResetState()
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
