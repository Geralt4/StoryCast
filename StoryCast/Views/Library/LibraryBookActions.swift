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
    }

    func deleteBook(_ book: Book, saveChanges: Bool = true) async throws {
        await deleteBookFiles(for: book)
        modelContext.delete(book)

        if saveChanges {
            try modelContext.save()
        }
    }

    func deleteBooks(_ books: [Book]) async throws {
        for book in books {
            try await deleteBook(book, saveChanges: false)
        }

        try modelContext.save()
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
