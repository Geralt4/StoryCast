import Foundation
import SwiftData
import os

@MainActor
final class LibraryBookActions {
    private unowned let modelContext: ModelContext
    private let remoteHandler: LibraryRemoteBookHandler

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.remoteHandler = LibraryRemoteBookHandler(modelContext: modelContext)
    }

    func fetchAllFolders() throws -> [Folder] {
        let request = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\Folder.sortOrder)])
        return try modelContext.fetch(request)
    }

    func moveBook(_ book: Book, to folder: Folder) throws {
        book.folder = folder
        try modelContext.save()
        Task {
            await SyncController.shared.synchronizeIfEnabled(
                container: modelContext.container,
                auditLibrary: false
            )
        }
    }

    func deleteBook(_ book: Book, saveChanges: Bool = true) async throws {
        let deletedLocalBookID = book.isRemote ? nil : book.id
        await deleteBookFiles(for: book)
        modelContext.delete(book)

        if saveChanges {
            try modelContext.save()
            if let deletedLocalBookID {
                await SyncController.shared.recordDeletion(
                    entityKind: .book,
                    entityID: deletedLocalBookID.uuidString,
                    container: modelContext.container
                )
            }
        }
    }

    func deleteBooks(_ books: [Book]) async throws {
        let deletedLocalBookIDs = books.filter { !$0.isRemote }.map(\.id)
        for book in books {
            try await deleteBook(book, saveChanges: false)
        }

        try modelContext.save()
        for bookID in deletedLocalBookIDs {
            await SyncController.shared.recordDeletion(
                entityKind: .book,
                entityID: bookID.uuidString,
                container: modelContext.container
            )
        }
    }

    func downloadBook(_ book: Book) {
        remoteHandler.downloadBook(book)
    }

    func removeDownloadedBook(_ book: Book) {
        remoteHandler.removeDownloadedBook(book)
    }

    private func deleteBookFiles(for book: Book) async {
        if book.isRemote {
            if let cachePath = book.localCachePath {
                await StorageManager.shared.deleteRemoteAudioCache(fileName: cachePath)
            }
        } else if !book.localFileName.isEmpty {
            let audioURL = StorageManager.shared.storyCastLibraryURL.appendingPathComponent(book.localFileName)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                do {
                    try FileManager.default.removeItem(at: audioURL)
                } catch {
                    AppLogger.ui.error("Error deleting audio file: \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        if let coverArtFileName = book.coverArtFileName {
            await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName, isRemote: book.isRemote)
        }
    }
}
