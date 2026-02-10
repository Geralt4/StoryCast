import SwiftUI
import SwiftData
import os

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSelecting = false
    @Query private var folderBooks: [Book]

    let folder: Folder

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

    @EnvironmentObject private var importService: ImportService
    @State private var showFileImporter = false
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var showFolderError = false
    @State private var folderErrorMessage = ""
    @State private var searchText = ""

    @State private var selectedBook: Book?

    @State private var selectedBookIds: Set<UUID> = []
    @State private var showBulkMoveToFolder = false
    @State private var showBulkDeleteConfirmation = false
    @State private var actionTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var filteredBooks: [Book] {
        guard isSearching else { return folderBooks }
        return folderBooks.filter(bookMatchesSearch)
    }

    private var isEditing: Bool {
        isSelecting
    }

    private var selectableBookIds: Set<UUID> {
        Set(folderBooks.map { $0.id })
    }

    private var isAllSelected: Bool {
        !selectableBookIds.isEmpty && selectedBookIds.isSuperset(of: selectableBookIds)
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedBookIds.removeAll()
        } else {
            selectedBookIds = selectableBookIds
        }
    }

    var body: some View {
        detailView
    }

    @ViewBuilder
    private var detailView: some View {
        let listView = FolderDetailListView(
            folderBooks: filteredBooks,
            isEditing: isEditing,
            selectedBookIds: $selectedBookIds,
            onDeleteBooks: deleteBooks,
            onSelect: { book in
                if !isSelecting {
                    isSelecting = true
                }
                if selectedBookIds.contains(book.id) {
                    selectedBookIds.remove(book.id)
                } else {
                    selectedBookIds.insert(book.id)
                }
            },
            onMove: { book in
                selectedBook = book
            },
            onDelete: deleteBookAction,
            emptyStateTitle: isSearching ? "No Results" : "No Books",
            emptyStateDescription: isSearching ? "Try a different search." : "This folder is empty"
        )
        let navigationView = listView
            .navigationTitle(folder.name)
            .searchable(text: $searchText, prompt: "Search books")
        let toolbarView = navigationView
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Done" : "Select") {
                        HapticManager.impact(.light)
                        withAnimation {
                            if isSelecting {
                                isSelecting = false
                                selectedBookIds.removeAll()
                            } else {
                                isSelecting = true
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isEditing {
                        Button(action: {
                            HapticManager.impact(.light)
                            showFileImporter = true
                        }) {
                            Label("Import", systemImage: "doc.badge.plus")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if isEditing {
                        if !selectableBookIds.isEmpty {
                            Button(action: {
                                HapticManager.impact(.light)
                                toggleSelectAll()
                            }) {
                                Label(isAllSelected ? "Deselect All" : "Select All", systemImage: isAllSelected ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.check")
                            }
                            Spacer()
                        }
                        if !selectedBookIds.isEmpty {
                            Button {
                                HapticManager.impact(.light)
                                showBulkMoveToFolder = true
                            } label: {
                                Label("Move", systemImage: "folder")
                            }
                            Spacer()
                            Button(role: .destructive) {
                                HapticManager.impact(.heavy)
                                HapticManager.notification(.warning)
                                showBulkDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        let destinationView = toolbarView
            .navigationDestination(for: Book.self) { book in
                PlayerView(book: book)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: SupportedFormats.voiceBoxAudioTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importFiles(urls)
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    showImportError = true
                }
            }
        let alertView = destinationView
            .alert("Import Result", isPresented: $showImportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importErrorMessage)
            }
            .alert("Library Error", isPresented: $showFolderError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(folderErrorMessage)
            }
        let overlayView = alertView
            .overlay {
                if importService.isImporting {
                    ImportProgressOverlay(importService: importService) {
                        importService.cancelImport()
                    }
                }
            }
            .sheet(item: $selectedBook) { book in
                MoveToFolderSheet(
                    book: book,
                    folders: getAllFolders(),
                    onSave: { folder in
                        moveBook(book, to: folder)
                        selectedBook = nil
                    },
                    onCancel: {
                        selectedBook = nil
                    }
                )
            }
            .sheet(isPresented: $showBulkMoveToFolder) {
                BulkMoveToFolderSheet(
                    bookIds: selectedBookIds,
                    folders: getAllFolders(),
                    currentFolder: folder,
                    onSave: { folder in
                        moveSelectedBooks(to: folder)
                        selectedBookIds.removeAll()
                        showBulkMoveToFolder = false
                    },
                    onCancel: {
                        showBulkMoveToFolder = false
                    }
                )
            }
            .sheet(isPresented: $showBulkDeleteConfirmation) {
                BulkDeleteConfirmationSheet(
                    count: selectedBookIds.count,
                    onConfirm: {
                        actionTask?.cancel()
                        actionTask = Task {
                            await deleteSelectedBooks()
                            guard !Task.isCancelled else { return }
                            selectedBookIds.removeAll()
                            showBulkDeleteConfirmation = false
                        }
                    },
                    onCancel: {
                        showBulkDeleteConfirmation = false
                    }
                )
            }
        let finalView = overlayView
            .onChange(of: folderBooks.map(\.id)) { _, _ in
                selectedBookIds = selectedBookIds.intersection(selectableBookIds)
            }
            .onDisappear {
                actionTask?.cancel()
                importTask?.cancel()
            }
        finalView
    }

    private func moveSelectedBooks(to folder: Folder) {
        for bookId in selectedBookIds {
            if let book = folderBooks.first(where: { $0.id == bookId }) {
                book.folder = folder
            }
        }
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to move books", error: error)
        }
    }

    @MainActor
    private func deleteSelectedBooks() async {
        for bookId in selectedBookIds {
            if let book = folderBooks.first(where: { $0.id == bookId }) {
                await deleteBook(book, saveChanges: false)
            }
        }
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to delete books", error: error)
        }
    }

    private func importFiles(_ urls: [URL]) {
        importTask?.cancel()
        importTask = Task {
            await importService.importFilesToFolder(urls: urls, folderId: folder.id, container: modelContext.container)
            guard !Task.isCancelled else { return }
            let failedCount = importService.importErrors.count
            let skippedCount = importService.skippedDuplicateFileNames.count
            let importedCount = importService.completedFiles

            if failedCount > 0 {
                importErrorMessage = "Failed to import \(failedCount) files."
                if skippedCount > 0 {
                    let suffix = skippedCount == 1 ? "file is" : "files are"
                    importErrorMessage += " \(skippedCount) \(suffix) already in your library."
                }
                showImportError = true
                return
            }

            if skippedCount > 0 {
                if importedCount > 0 {
                    let importedSuffix = importedCount == 1 ? "file" : "files"
                    let skippedSuffix = skippedCount == 1 ? "file is" : "files are"
                    importErrorMessage = "Imported \(importedCount) \(importedSuffix). \(skippedCount) \(skippedSuffix) already in your library."
                } else {
                    let skippedSuffix = skippedCount == 1 ? "file is" : "files are"
                    importErrorMessage = "No new files imported. \(skippedCount) \(skippedSuffix) already in your library."
                }
                showImportError = true
            }
        }
    }
    
    private func getAllFolders() -> [Folder] {
        let request = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])
        do {
            return try modelContext.fetch(request)
        } catch {
            presentError("Failed to load folders", error: error)
            return []
        }
    }
    
    private func deleteBooks(offsets: IndexSet) {
        actionTask?.cancel()
        actionTask = Task {
            await deleteBooksAsync(offsets: offsets)
        }
    }
    
    private func deleteBookAction(_ book: Book) {
        actionTask?.cancel()
        actionTask = Task {
            await deleteBook(book)
        }
    }

    @MainActor
    private func deleteBooksAsync(offsets: IndexSet) async {
        let booksToDelete: [Book] = offsets.compactMap { index in
            guard filteredBooks.indices.contains(index) else { return nil }
            return filteredBooks[index]
        }
        for book in booksToDelete {
            await deleteBook(book, saveChanges: false)
        }
do {
            try modelContext.save()
} catch {
            presentError("Failed to delete books", error: error)
        }
    }

    @MainActor
    private func deleteBook(_ book: Book, saveChanges: Bool = true) async {
        let audioURL = StorageManager.shared.storyCastLibraryURL
            .appendingPathComponent(book.localFileName)
        do {
            try FileManager.default.removeItem(at: audioURL)
        } catch {
            AppLogger.ui.error("Error deleting audio file: \(error.localizedDescription, privacy: .private)")
        }
        if let coverArtFileName = book.coverArtFileName {
            await StorageManager.shared.deleteCoverArt(fileName: coverArtFileName)
        }
        modelContext.delete(book)
        if saveChanges {
            do {
                try modelContext.save()
            } catch {
                presentError("Failed to delete book", error: error)
            }
        }
    }
    
    private func moveBook(_ book: Book, to folder: Folder) {
        book.folder = folder
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to move book", error: error)
        }
    }

    private func presentError(_ message: String, error: Error) {
        folderErrorMessage = "\(message): \(error.localizedDescription)"
        showFolderError = true
    }

    private func bookMatchesSearch(_ book: Book) -> Bool {
        let query = normalizedSearchText.lowercased()
        if book.title.lowercased().contains(query) {
            return true
        }
        if let author = book.author?.lowercased(), author.contains(query) {
            return true
        }
        return false
    }
}

#Preview {
    NavigationStack {
        FolderDetailView(folder: Folder(name: "Test Folder"))
    }
    .modelContainer(for: [Book.self, Chapter.self, Folder.self], inMemory: true)
    .environmentObject(ImportService.shared)
}
