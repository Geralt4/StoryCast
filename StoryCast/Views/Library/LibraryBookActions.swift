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

    func deleteBook(_ book: Book) async throws {
        let containsLocalBook = !book.isRemote
        let deviceID = containsLocalBook ? try? await SyncDeviceIdentity.shared.identifier() : nil
        let context = modelContext

        do {
            try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: deviceID, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        StorageCleanupCoordinator.drainPendingCleanup(in: context)
        if containsLocalBook {
            await SyncController.shared.synchronizeIfEnabled(
                container: context.container,
                auditLibrary: false
            )
        }
    }

    func deleteBooks(_ books: [Book]) async throws {
        guard !books.isEmpty else { return }

        let containsLocalBook = books.contains { !$0.isRemote }
        let deviceID = containsLocalBook ? try? await SyncDeviceIdentity.shared.identifier() : nil
        let context = modelContext

        do {
            for book in books {
                try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: deviceID, in: context)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        StorageCleanupCoordinator.drainPendingCleanup(in: context)
        if containsLocalBook {
            await SyncController.shared.synchronizeIfEnabled(
                container: context.container,
                auditLibrary: false
            )
        }
    }

    func downloadBook(_ book: Book) {
        remoteHandler.downloadBook(book)
    }

    func removeDownloadedBook(_ book: Book) {
        remoteHandler.removeDownloadedBook(book)
    }

}
