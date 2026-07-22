import Foundation
import SwiftData
import os

/// Handles folder operations for the library view.
///
/// `LibraryFolderOperations` manages:
/// - Folder creation with unique naming
/// - Folder renaming
/// - Folder deletion with book reassignment
/// - Folder merging
/// - Bulk folder operations
///
/// ## Usage
///
/// ```swift
/// let operations = LibraryFolderOperations(modelContext: context)
/// let folder = operations.createFolder(name: "My Folder")
/// operations.renameFolder(folder, newName: "New Name")
/// operations.deleteFolder(folder)
/// ```
@MainActor
final class LibraryFolderOperations {
    private unowned let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    /// Creates a new folder with the given name.
    ///
    /// - Parameter name: The folder name (will be made unique if needed)
    /// - Returns: The created `Folder`
    func createFolder(name: String) -> Folder {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return createFolder(name: "New Folder")
        }
        
        let sortOrder = (getUserFolders().map { $0.sortOrder }.max() ?? 0) + 1
        let folderName = makeUniqueName(for: trimmedName)
        
        let folder = Folder(name: folderName, isSystem: false, sortOrder: sortOrder)
        modelContext.insert(folder)
        
        do {
            try modelContext.save()
            scheduleLibrarySync()
        } catch {
            AppLogger.storage.error("Failed to save new folder '\(folderName)': \(error.localizedDescription)")
            modelContext.rollback()
        }
        return folder
    }
    
    /// Renames a folder with the given name.
    ///
    /// - Parameters:
    ///   - folder: The folder to rename
    ///   - newName: The new name (will be made unique if needed)
    func renameFolder(_ folder: Folder, newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let uniqueName = makeUniqueName(for: trimmedName, excluding: folder.id)
        
        if folder.name != uniqueName {
            folder.name = uniqueName
            do {
                try modelContext.save()
                scheduleLibrarySync()
            } catch {
                AppLogger.storage.error("Failed to save folder rename: \(error.localizedDescription)")
                modelContext.rollback()
            }
        }
    }
    
    /// Deletes a folder, moving its books to Unfiled.
    ///
    /// - Parameter folder: The folder to delete
    func deleteFolder(_ folder: Folder) async throws {
        guard let unfiled = try fetchUnfiledFolder() else { return }
        try await deleteFolderWithDestination(folder, destination: unfiled)
    }
    
    /// Deletes a folder, moving its books to a specific destination folder.
    ///
    /// - Parameters:
    ///   - folder: The folder to delete
    ///   - destination: The folder to receive the books
    func deleteFolderWithDestination(_ folder: Folder, destination: Folder) async throws {
        let deletedFolderID = folder.id
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()

        do {
            for book in folder.books {
                book.folder = destination
            }
            try LibraryDeletionTransaction.stageFolderDeletion(id: deletedFolderID, deviceID: deviceID, in: modelContext)
            modelContext.delete(folder)
            try modelContext.save()
        } catch {
            AppLogger.storage.error("Failed to save folder deletion: \(error.localizedDescription)")
            modelContext.rollback()
            throw error
        }
        await synchronizeAfterFolderDeletion()
    }
    
    /// Merges a source folder into a target folder.
    ///
    /// - Parameters:
    ///   - sourceFolder: The folder to merge from
    ///   - targetFolder: The folder to merge into
    func mergeFolder(_ sourceFolder: Folder, into targetFolder: Folder) async throws {
        let deletedFolderID = sourceFolder.id
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()

        do {
            for book in sourceFolder.books {
                book.folder = targetFolder
            }
            try LibraryDeletionTransaction.stageFolderDeletion(id: deletedFolderID, deviceID: deviceID, in: modelContext)
            modelContext.delete(sourceFolder)
            try modelContext.save()
        } catch {
            AppLogger.storage.error("Failed to save folder merge: \(error.localizedDescription)")
            modelContext.rollback()
            throw error
        }
        await synchronizeAfterFolderDeletion()
    }
    
    /// Moves multiple folders into a target folder.
    ///
    /// - Parameters:
    ///   - folderIds: IDs of folders to move
    ///   - targetFolder: The destination folder
    func moveFolders(_ folderIds: Set<UUID>, into targetFolder: Folder) async throws {
        guard !folderIds.isEmpty else { return }
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()
        let folders = try modelContext.fetch(FetchDescriptor<Folder>())
        let foldersToDelete = folders.filter { folderIds.contains($0.id) && !$0.isSystem && $0.id != targetFolder.id }

        do {
            for folder in foldersToDelete {
                for book in folder.books {
                    book.folder = targetFolder
                }
                try LibraryDeletionTransaction.stageFolderDeletion(id: folder.id, deviceID: deviceID, in: modelContext)
                modelContext.delete(folder)
            }
            try modelContext.save()
        } catch {
            AppLogger.storage.error("Failed to save folder move operation: \(error.localizedDescription)")
            modelContext.rollback()
            throw error
        }
        if !foldersToDelete.isEmpty { await synchronizeAfterFolderDeletion() }
    }
    
    /// Deletes multiple folders, moving books to Unfiled.
    ///
    /// - Parameter folderIds: IDs of folders to delete
    func deleteFolders(_ folderIds: Set<UUID>) async throws {
        guard !folderIds.isEmpty, let unfiled = try fetchUnfiledFolder() else { return }
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()
        let folders = try modelContext.fetch(FetchDescriptor<Folder>())
        let foldersToDelete = folders.filter { folderIds.contains($0.id) && !$0.isSystem }

        do {
            for folder in foldersToDelete {
                for book in folder.books {
                    book.folder = unfiled
                }
                try LibraryDeletionTransaction.stageFolderDeletion(id: folder.id, deviceID: deviceID, in: modelContext)
                modelContext.delete(folder)
            }
            try modelContext.save()
        } catch {
            AppLogger.storage.error("Failed to save bulk folder deletion: \(error.localizedDescription)")
            modelContext.rollback()
            throw error
        }
        if !foldersToDelete.isEmpty { await synchronizeAfterFolderDeletion() }
    }
    
    /// Gets the Unfiled system folder.
    ///
    /// - Returns: The Unfiled folder, or nil if not found
    func getUnfiledFolder() -> Folder? {
        getUserFolders().first { $0.isSystem }
    }
    
    // MARK: - Private
    
    private func getUserFolders() -> [Folder] {
        do {
            return try modelContext.fetch(FetchDescriptor<Folder>())
        } catch {
            AppLogger.storage.error("Failed to fetch folders: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private func fetchUnfiledFolder() throws -> Folder? {
        try modelContext.fetch(FetchDescriptor<Folder>()).first { $0.isSystem }
    }

    private func synchronizeAfterFolderDeletion() async {
        await SyncController.shared.synchronizeIfEnabled(
            container: modelContext.container,
            auditLibrary: false
        )
    }
    
    private func makeUniqueName(for name: String, excluding folderId: UUID? = nil) -> String {
        let existingNames = Set(getUserFolders()
            .filter { $0.id != folderId }
            .map { $0.name })
        
        guard existingNames.contains(name) else {
            return name
        }
        
        var counter = 2
        var candidateName = ""
        
        repeat {
            candidateName = "\(name) (\(counter))"
            counter += 1
        } while existingNames.contains(candidateName)
        
        return candidateName
    }

    private func scheduleLibrarySync() {
        let container = modelContext.container
        Task {
            await SyncController.shared.synchronizeIfEnabled(
                container: container,
                auditLibrary: false
            )
        }
    }
}
