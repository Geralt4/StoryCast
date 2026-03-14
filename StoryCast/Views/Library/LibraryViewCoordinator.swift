import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewCoordinator {
    var isSelecting = false
    var showSettings = false
    var showNewFolderSheet = false
    var showFolderSelection = false
    var showFileImporter = false
    var selectedFolderIds: Set<UUID> = []
    var showBulkMoveSheet = false
    var showBulkDeleteSheet = false
    var folderToMerge: Folder?
    var showRenameAlert = false
    var renameText = ""
    var folderToRename: Folder?
    var showDeleteConfirmation = false
    var folderToDelete: Folder?
    var searchBookToMove: Book?
    var searchBookToDelete: Book?
    var showSearchBookDeleteConfirmation = false
    var pendingImportURLs: [URL] = []
    var selectedFolderForImport: Folder?

    var isEditing: Bool {
        isSelecting
    }

    func toggleSelectionMode() {
        if isSelecting {
            isSelecting = false
            selectedFolderIds.removeAll()
        } else {
            isSelecting = true
        }
    }

    func toggleSelectAll(selectableFolderIds: Set<UUID>) {
        if !selectableFolderIds.isEmpty && selectedFolderIds.isSuperset(of: selectableFolderIds) {
            selectedFolderIds.removeAll()
        } else {
            selectedFolderIds = selectableFolderIds
        }
    }

    func selectFolder(_ folder: Folder) {
        guard !folder.isSystem else { return }

        if !isSelecting {
            isSelecting = true
        }

        if selectedFolderIds.contains(folder.id) {
            selectedFolderIds.remove(folder.id)
        } else {
            selectedFolderIds.insert(folder.id)
        }
    }

    func beginFolderRename(_ folder: Folder) {
        folderToRename = folder
        renameText = folder.name
        showRenameAlert = true
    }

    func finishFolderRename() {
        folderToRename = nil
    }

    func beginFolderDeletion(_ folder: Folder) {
        folderToDelete = folder
        showDeleteConfirmation = true
    }

    func finishFolderDeletion() {
        folderToDelete = nil
    }

    func queueImports(_ urls: [URL]) {
        pendingImportURLs = urls
        showFolderSelection = true
    }

    func completeFolderImportSelection() {
        pendingImportURLs = []
        selectedFolderForImport = nil
        showFolderSelection = false
    }

    func cancelFolderImportSelection() {
        selectedFolderForImport = nil
        showFolderSelection = false
    }

    func beginSearchBookMove(_ book: Book) {
        searchBookToMove = book
    }

    func finishSearchBookMove() {
        searchBookToMove = nil
    }

    func beginSearchBookDeletion(_ book: Book) {
        searchBookToDelete = book
        showSearchBookDeleteConfirmation = true
    }

    func finishSearchBookDeletion() {
        searchBookToDelete = nil
        showSearchBookDeleteConfirmation = false
    }
}
