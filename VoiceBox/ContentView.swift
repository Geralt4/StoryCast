import SwiftUI
import SwiftData
import os

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("isUsingInMemoryStorage") private var isUsingInMemoryStorage = false
    @AppStorage("hasCompletedLegacyLibraryDeduplication") private var hasCompletedLegacyLibraryDeduplication = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showStorageWarning = false

    var body: some View {
        Group {
            if let error = loadError {
                ContentUnavailableView {
                    Label("Error Loading App", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        loadError = nil
                        isLoading = true
                        Task {
                            await initializeApp()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if isLoading {
                ProgressView("Loading...")
            } else {
                LibraryView()
            }
        }
        .task {
            showStorageWarning = isUsingInMemoryStorage
            await initializeApp()
        }
        .alert("Storage Warning", isPresented: $showStorageWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your data is being stored in memory only due to a storage initialization failure. Changes will not persist after closing the app.")
        }
    }

    @MainActor
    private func initializeApp() async {
        prewarmCoreServices()

        let container = modelContext.container

        // Ensure Unfiled folder exists exactly once before any concurrent work
        ensureUnfiledFolderExists(container: container)

        await prewarmAppResources()
        await repairLibraryIntegrity(container: container)
        await scanAndImportExistingFiles(container: container)
        if !hasCompletedLegacyLibraryDeduplication {
            let didCompleteDeduplication = await deduplicateExistingBooks(container: container)
            if didCompleteDeduplication {
                hasCompletedLegacyLibraryDeduplication = true
            }
        }

        isLoading = false
    }

    private func ensureUnfiledFolderExists(container: ModelContainer) {
        let context = ModelContext(container)
        var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        unfiledFetch.fetchLimit = 1
        let existing = try? context.fetch(unfiledFetch).first
        if existing == nil {
            let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
            context.insert(folder)
            try? context.save()
        }
    }

    private func scanAndImportExistingFiles(container: ModelContainer) async {
        let voiceBoxLibraryPath = StorageManager.shared.voiceBoxLibraryURL.path

        // Fetch the Unfiled folder (guaranteed to exist from ensureUnfiledFolderExists)
        let context = ModelContext(container)
        var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        unfiledFetch.fetchLimit = 1
        guard let unfiledFolder = try? context.fetch(unfiledFetch).first else { return }
        let unfiledFolderId = unfiledFolder.id

        let descriptor = FetchDescriptor<Book>()
        guard let books = try? context.fetch(descriptor) else { return }

        let libraryURL = StorageManager.shared.voiceBoxLibraryURL
        let existingFileNames = Set(books.compactMap { book in
            let localFileURL = libraryURL.appendingPathComponent(book.localFileName)
            return FileManager.default.fileExists(atPath: localFileURL.path) ? book.localFileName : nil
        })

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: voiceBoxLibraryPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var unimportedFileURLs: [URL] = []

        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent

            if !existingFileNames.contains(fileName) && SupportedFormats.isSupported(fileURL) {
                unimportedFileURLs.append(fileURL)
            }
        }

        if !unimportedFileURLs.isEmpty {
            await ImportService.shared.importFilesToFolder(
                urls: unimportedFileURLs,
                folderId: unfiledFolderId,
                container: container
            )
        }
    }

    private func repairLibraryIntegrity(container: ModelContainer) async {
        enum RepairResult: Sendable {
            case success(staleRemovedCount: Int, reassignedToUnfiledCount: Int, coverArtFileNames: [String], createdUnfiledFolder: Bool)
            case failure(message: String)
        }

        let repairResult = await Task.detached(priority: .utility) { () -> RepairResult in
            do {
                let context = ModelContext(container)

                var unfiledCreated = false
                var unfiledFetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
                unfiledFetch.fetchLimit = 1

                let unfiledFolder: Folder
                if let existing = try context.fetch(unfiledFetch).first {
                    unfiledFolder = existing
                } else {
                    let createdFolder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
                    context.insert(createdFolder)
                    unfiledFolder = createdFolder
                    unfiledCreated = true
                }

                let books = try context.fetch(FetchDescriptor<Book>())
                guard !books.isEmpty else {
                    if unfiledCreated {
                        try context.save()
                    }
                    return .success(staleRemovedCount: 0, reassignedToUnfiledCount: 0, coverArtFileNames: [], createdUnfiledFolder: unfiledCreated)
                }

                let libraryURL = StorageManager.shared.voiceBoxLibraryURL
                var coverArtFileNamesToDelete = Set<String>()
                var booksToDelete: [Book] = []
                var reassignedToUnfiledCount = 0

                for book in books {
                    let localFileURL = libraryURL.appendingPathComponent(book.localFileName)
                    if !FileManager.default.fileExists(atPath: localFileURL.path) {
                        booksToDelete.append(book)
                        if let coverArtFileName = book.coverArtFileName {
                            coverArtFileNamesToDelete.insert(coverArtFileName)
                        }
                        continue
                    }

                    if book.folder == nil {
                        book.folder = unfiledFolder
                        reassignedToUnfiledCount += 1
                    }
                }

                for book in booksToDelete {
                    context.delete(book)
                }

                if unfiledCreated || reassignedToUnfiledCount > 0 || !booksToDelete.isEmpty {
                    try context.save()
                }

                return .success(
                    staleRemovedCount: booksToDelete.count,
                    reassignedToUnfiledCount: reassignedToUnfiledCount,
                    coverArtFileNames: Array(coverArtFileNamesToDelete),
                    createdUnfiledFolder: unfiledCreated
                )
            } catch {
                return .failure(message: error.localizedDescription)
            }
        }.value

        switch repairResult {
        case .failure(let message):
            AppLogger.app.error("Library integrity repair failed: \(message, privacy: .private)")
        case .success(let staleRemovedCount, let reassignedToUnfiledCount, let coverArtFileNames, let createdUnfiledFolder):
            for coverArtFileName in coverArtFileNames {
                await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName)
            }

            if staleRemovedCount > 0 || reassignedToUnfiledCount > 0 || createdUnfiledFolder {
                AppLogger.app.info("Library integrity repair completed: removed \(staleRemovedCount) stale books, reassigned \(reassignedToUnfiledCount) books to Unfiled")
            }
        }
    }

    private func deduplicateExistingBooks(container: ModelContainer) async -> Bool {
        enum DeduplicationResult: Sendable {
            case success(localFileNames: [String], coverArtFileNames: [String], removedCount: Int)
            case failure(message: String)
        }

        let deduplicationResult = await Task.detached(priority: .utility) { () -> DeduplicationResult in
            do {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<Book>()
                let books = try context.fetch(descriptor)

                guard !books.isEmpty else {
                    return .success(localFileNames: [], coverArtFileNames: [], removedCount: 0)
                }

                func normalized(_ value: String) -> String {
                    value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }

                func deduplicationKey(for book: Book) -> String {
                    let normalizedTitle = normalized(book.title)
                    let normalizedAuthor = normalized(book.author ?? "")
                    return "\(normalizedTitle)|\(normalizedAuthor)"
                }

                func shouldPrefer(_ lhs: Book, over rhs: Book) -> Bool {
                    let lhsDate = lhs.lastPlayedDate ?? .distantPast
                    let rhsDate = rhs.lastPlayedDate ?? .distantPast
                    if lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    if lhs.lastPlaybackPosition != rhs.lastPlaybackPosition {
                        return lhs.lastPlaybackPosition > rhs.lastPlaybackPosition
                    }
                    return lhs.id.uuidString > rhs.id.uuidString
                }

                let libraryURL = StorageManager.shared.voiceBoxLibraryURL
                var localFileNamesToDelete = Set<String>()
                var coverArtFileNamesToDelete = Set<String>()
                var booksToDelete: [Book] = []

                var activeBooks: [Book] = []
                activeBooks.reserveCapacity(books.count)
                for book in books {
                    let localFileURL = libraryURL.appendingPathComponent(book.localFileName)
                    if FileManager.default.fileExists(atPath: localFileURL.path) {
                        activeBooks.append(book)
                    } else {
                        booksToDelete.append(book)
                        if let coverArtFileName = book.coverArtFileName {
                            coverArtFileNamesToDelete.insert(coverArtFileName)
                        }
                    }
                }

                let groupedBooks = Dictionary(grouping: activeBooks, by: deduplicationKey)

                for group in groupedBooks.values where group.count > 1 {
                    let sortedByDuration = group.sorted { $0.duration < $1.duration }
                    var cluster: [Book] = []
                    var clusterAnchorDuration: Double = 0

                    func processCluster(_ booksInCluster: [Book]) {
                        guard booksInCluster.count > 1 else { return }
                        var keeper = booksInCluster[0]
                        for candidate in booksInCluster.dropFirst() {
                            if shouldPrefer(candidate, over: keeper) {
                                keeper = candidate
                            }
                        }

                        for book in booksInCluster where book.id != keeper.id {
                            booksToDelete.append(book)
                            localFileNamesToDelete.insert(book.localFileName)
                            if let coverArtFileName = book.coverArtFileName {
                                coverArtFileNamesToDelete.insert(coverArtFileName)
                            }
                        }
                    }

                    for book in sortedByDuration {
                        if cluster.isEmpty {
                            cluster = [book]
                            clusterAnchorDuration = book.duration
                            continue
                        }

                        if abs(book.duration - clusterAnchorDuration) <= 1.0 {
                            cluster.append(book)
                        } else {
                            processCluster(cluster)
                            cluster = [book]
                            clusterAnchorDuration = book.duration
                        }
                    }

                    processCluster(cluster)
                }

                for book in booksToDelete {
                    context.delete(book)
                }

                let removedCount = booksToDelete.count

                if removedCount > 0 {
                    try context.save()
                }

                return .success(
                    localFileNames: Array(localFileNamesToDelete),
                    coverArtFileNames: Array(coverArtFileNamesToDelete),
                    removedCount: removedCount
                )
            } catch {
                return .failure(message: error.localizedDescription)
            }
        }.value

        switch deduplicationResult {
        case .failure(let message):
            AppLogger.app.error("Library deduplication failed: \(message, privacy: .private)")
            return false
        case .success(let localFileNames, let coverArtFileNames, let removedCount):
            guard removedCount > 0 else {
                AppLogger.app.info("Library deduplication completed: no duplicates found")
                return true
            }

            let libraryURL = StorageManager.shared.voiceBoxLibraryURL
            for fileName in localFileNames {
                let fileURL = libraryURL.appendingPathComponent(fileName)
                await Task.detached(priority: .utility) {
                    let fileManager = FileManager.default
                    guard fileManager.fileExists(atPath: fileURL.path) else { return }
                    try? fileManager.removeItem(at: fileURL)
                }.value
            }

            for fileName in coverArtFileNames {
                await StorageManager.shared.deleteCoverArt(fileName: fileName)
            }

            AppLogger.app.info("Library deduplication removed \(removedCount) duplicate books")
            return true
        }
    }

    @MainActor
    private func prewarmCoreServices() {
        _ = SleepTimerService.shared
        _ = PlaybackSettings.load()
        _ = SleepTimerSettings.load()
    }

    @MainActor
    private func prewarmAppResources() async {
        let container = modelContext.container
        
        async let swiftDataTask: Void = Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)
            var folderFetch = FetchDescriptor<Folder>()
            folderFetch.fetchLimit = 1
            _ = try? backgroundContext.fetch(folderFetch)

            var bookFetch = FetchDescriptor<Book>()
            bookFetch.fetchLimit = 1
            _ = try? backgroundContext.fetch(bookFetch)
        }.value

        async let storageTask: Void = Task.detached(priority: .utility) {
            do {
                    try await StorageManager.shared.setupVoiceBoxLibraryDirectory()
                    try await StorageManager.shared.setupCoverArtDirectory()
                    try await StorageManager.shared.migrateFileProtectionIfNeeded()
                } catch {
                    AppLogger.storage.error("Failed to prewarm storage directories: \(error.localizedDescription, privacy: .private)")
                }
        }.value
        
        _ = await (swiftDataTask, storageTask)
    }
}

#Preview {
    ContentView()
        .environmentObject(ImportService.shared)
        .modelContainer(for: [Book.self, Chapter.self, Folder.self], inMemory: true)
}
