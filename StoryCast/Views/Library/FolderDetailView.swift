import SwiftData
import SwiftUI

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var importService: ImportService
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]
    @Query private var folderBooks: [Book]

    let folder: Folder

    @State private var searchHandler = FolderBookSearchHandler()
    @State private var importHandler = LibraryImportHandler()
    @State private var coordinator = FolderDetailCoordinator()
    @State private var actionTask: Task<Void, Never>?
    @State private var showFolderError = false
    @State private var folderErrorMessage = ""

    init(folder: Folder) {
        self.folder = folder
        let folderId = folder.id
        _folderBooks = Query(
            filter: #Predicate<Book> { book in
                book.folder?.id == folderId
            },
            sort: \Book.title
        )
    }

    private var bookActions: LibraryBookActions {
        LibraryBookActions(modelContext: modelContext)
    }

    private var filteredBooks: [Book] {
        searchHandler.filteredBooks(from: folderBooks)
    }

    private var selectableBookIds: Set<UUID> {
        Set(folderBooks.map { $0.id })
    }

    private var isAllSelected: Bool {
        !selectableBookIds.isEmpty && coordinator.selectedBookIds.isSuperset(of: selectableBookIds)
    }

    var body: some View {
        FolderDetailListView(
            folderBooks: filteredBooks,
            isEditing: coordinator.isEditing,
            selectedBookIds: $coordinator.selectedBookIds,
            onDeleteBooks: { offsets in
                let books: [Book] = offsets.compactMap { filteredBooks.indices.contains($0) ? filteredBooks[$0] : nil }
                deleteBooks(books)
            },
            onSelect: { book in
                coordinator.toggleSelection(for: book)
            },
            onMove: { book in
                coordinator.beginMove(for: book)
            },
            onDelete: { book in
                deleteBooks([book])
            },
            onDownload: { book in
                bookActions.downloadBook(book)
            },
            onRemoveDownload: { book in
                bookActions.removeDownloadedBook(book)
            },
            emptyStateTitle: searchHandler.isSearching ? "No Results" : "No Books",
            emptyStateDescription: searchHandler.isSearching ? "Try a different search." : "This folder is empty"
        )
        .navigationTitle(folder.name)
        .searchable(text: $searchHandler.searchText, prompt: "Search books")
        .onChange(of: searchHandler.searchText) { _, _ in
            searchHandler.updateSearchText(searchHandler.searchText, books: folderBooks)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(coordinator.isEditing ? "Done" : "Select") {
                    HapticManager.impact(.light)
                    withAnimation {
                        coordinator.toggleSelectionMode()
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !coordinator.isEditing {
                    Button(action: {
                        HapticManager.impact(.light)
                        coordinator.showFileImporter = true
                    }) {
                        Label("Import", systemImage: "doc.badge.plus")
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if coordinator.isEditing {
                    if !selectableBookIds.isEmpty {
                        Button(action: {
                            HapticManager.impact(.light)
                            coordinator.toggleSelectAll(selectableBookIds: selectableBookIds)
                        }) {
                            Label(
                                isAllSelected ? "Deselect All" : "Select All",
                                systemImage: isAllSelected ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.check"
                            )
                        }
                        Spacer()
                    }
                    if !coordinator.selectedBookIds.isEmpty {
                        Button {
                            HapticManager.impact(.light)
                            coordinator.showBulkMoveToFolder = true
                        } label: {
                            Label("Move", systemImage: "folder")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            HapticManager.impact(.heavy)
                            HapticManager.notification(.warning)
                            coordinator.showBulkDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Book.self) { book in
            PlayerView(book: book)
        }
        .fileImporter(
            isPresented: $coordinator.showFileImporter,
            allowedContentTypes: SupportedFormats.voiceBoxAudioTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importHandler.importFiles(urls, to: folder, importService: importService, modelContext: modelContext)
            case .failure(let error):
                importHandler.importErrorMessage = error.localizedDescription
                importHandler.showImportError = true
            }
        }
        .alert("Import Result", isPresented: $importHandler.showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importHandler.importErrorMessage)
        }
        .alert("Library Error", isPresented: $showFolderError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(folderErrorMessage)
        }
        .overlay {
            if importService.isImporting {
                ImportProgressOverlay(importService: importService) {
                    importHandler.cancelImport(importService: importService)
                }
            }
        }
        .sheet(item: $coordinator.selectedBook) { book in
            MoveToFolderSheet(
                book: book,
                folders: allFolders,
                onSave: { targetFolder in
                    do {
                        try bookActions.moveBook(book, to: targetFolder)
                        coordinator.finishMove()
                    } catch {
                        presentError("Failed to move book", error: error)
                    }
                },
                onCancel: {
                    coordinator.finishMove()
                }
            )
        }
        .sheet(isPresented: $coordinator.showBulkMoveToFolder) {
            BulkMoveToFolderSheet(
                bookIds: coordinator.selectedBookIds,
                folders: allFolders,
                currentFolder: folder,
                onSave: { targetFolder in
                    do {
                        try coordinator.moveSelectedBooks(from: folderBooks, using: bookActions, to: targetFolder)
                    } catch {
                        presentError("Failed to move books", error: error)
                    }
                    coordinator.selectedBookIds.removeAll()
                    coordinator.showBulkMoveToFolder = false
                },
                onCancel: {
                    coordinator.showBulkMoveToFolder = false
                }
            )
        }
        .sheet(isPresented: $coordinator.showBulkDeleteConfirmation) {
            BulkDeleteConfirmationSheet(
                count: coordinator.selectedBookIds.count,
                onConfirm: {
                    let books = coordinator.selectedBooks(from: folderBooks)
                    deleteBooks(books) {
                        coordinator.selectedBookIds.removeAll()
                        coordinator.showBulkDeleteConfirmation = false
                    }
                },
                onCancel: {
                    coordinator.showBulkDeleteConfirmation = false
                }
            )
        }
        .onChange(of: folderBooks.map(\.id)) { _, _ in
            coordinator.pruneSelection(to: selectableBookIds)
        }
        .onDisappear {
            actionTask?.cancel()
            importHandler.onDisappear()
            searchHandler.onDisappear()
        }
    }

    private func deleteBooks(_ books: [Book], onSuccess: (() -> Void)? = nil) {
        actionTask?.cancel()
        actionTask = Task {
            do {
                try await bookActions.deleteBooks(books)
                onSuccess?()
            } catch {
                presentError(books.count == 1 ? "Failed to delete book" : "Failed to delete books", error: error)
            }
        }
    }

    private func presentError(_ message: String, error: Error) {
        folderErrorMessage = "\(message): \(error.localizedDescription)"
        showFolderError = true
    }
}

#Preview {
    NavigationStack {
        FolderDetailView(folder: Folder(name: "Test Folder"))
    }
    .modelContainer(for: [Book.self, Chapter.self, Folder.self], inMemory: true)
    .environmentObject(ImportService.shared)
}
