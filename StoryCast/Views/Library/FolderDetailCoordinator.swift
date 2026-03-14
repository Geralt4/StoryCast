import Foundation
import Observation

@MainActor
@Observable
final class FolderDetailCoordinator {
    var isSelecting = false
    var showFileImporter = false
    var selectedBook: Book?
    var selectedBookIds: Set<UUID> = []
    var showBulkMoveToFolder = false
    var showBulkDeleteConfirmation = false

    var isEditing: Bool {
        isSelecting
    }

    func toggleSelectionMode() {
        if isSelecting {
            isSelecting = false
            selectedBookIds.removeAll()
        } else {
            isSelecting = true
        }
    }

    func toggleSelectAll(selectableBookIds: Set<UUID>) {
        if !selectableBookIds.isEmpty && selectedBookIds.isSuperset(of: selectableBookIds) {
            selectedBookIds.removeAll()
        } else {
            selectedBookIds = selectableBookIds
        }
    }

    func toggleSelection(for book: Book) {
        if !isSelecting {
            isSelecting = true
        }

        if selectedBookIds.contains(book.id) {
            selectedBookIds.remove(book.id)
        } else {
            selectedBookIds.insert(book.id)
        }
    }

    func pruneSelection(to selectableBookIds: Set<UUID>) {
        selectedBookIds = selectedBookIds.intersection(selectableBookIds)
    }

    func beginMove(for book: Book) {
        selectedBook = book
    }

    func finishMove() {
        selectedBook = nil
    }
}
