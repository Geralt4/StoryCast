import SwiftUI
import SwiftData
import Foundation
import os

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSelecting = false
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Book.title) private var allBooks: [Book]
    
    @EnvironmentObject private var importService: ImportService
    
    // UI State
    @State private var showFileImporter = false
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var showLibraryError = false
    @State private var libraryErrorMessage = ""
    @State private var showSettings = false
    @State private var showNewFolderSheet = false
    @State private var showFolderSelection = false
    @State private var pendingImportURLs: [URL] = []
    @State private var selectedFolderForImport: Folder?

    
    @State private var selectedFolderIds: Set<UUID> = []
    @State private var showBulkMoveSheet = false
    @State private var showBulkDeleteSheet = false

    @State private var folderToMerge: Folder?

    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var folderToRename: Folder?

    @State private var showDeleteConfirmation = false
    @State private var folderToDelete: Folder?
    @State private var cachedUnfiledFolder: Folder?
    @State private var importTask: Task<Void, Never>?
    @State private var retryTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var searchBookToMove: Book?
    @State private var showSearchBookDeleteConfirmation = false
    @State private var searchBookToDelete: Book?
    
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.automatic.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var sheetColorScheme: ColorScheme? {
        let mode = AppearanceMode(rawValue: appearanceModeRaw) ?? .automatic
        switch mode {
        case .automatic:
            return systemColorScheme
        case .light, .dark:
            return mode.colorScheme
        }
    }
    
    private var isEditing: Bool {
        isSelecting
    }
    
    private var unfiledFolder: Folder? {
        cachedUnfiledFolder
    }
    
    private var userFolders: [Folder] {
        folders.filter { !$0.isSystem }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var filteredFolders: [Folder] {
        guard isSearching else { return folders }
        let query = normalizedSearchText.lowercased()
        return folders.filter { $0.name.lowercased().contains(query) }
    }

    private var filteredBooks: [Book] {
        guard isSearching else { return allBooks }
        return deduplicatedSearchBooks(allBooks.filter(bookMatchesSearch))
    }
    
    private var hasAnyContent: Bool {
        !allBooks.isEmpty || !userFolders.isEmpty
    }

    private var selectableFolderIds: Set<UUID> {
        Set(userFolders.map { $0.id })
    }

    private var isAllSelected: Bool {
        !selectableFolderIds.isEmpty && selectedFolderIds.isSuperset(of: selectableFolderIds)
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedFolderIds.removeAll()
        } else {
            selectedFolderIds = selectableFolderIds
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchResultsSection
                } else if !hasAnyContent {
                    emptyStateView
                } else {
                    folderSection
                    failedImportsSection
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder)
            }
            .navigationDestination(for: Book.self) { book in
                PlayerView(book: book)
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        HapticManager.impact(.light)
                        showSettings = true
                    }) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Done" : "Select") {
                        HapticManager.impact(.light)
                        withAnimation {
                            if isSelecting {
                                isSelecting = false
                                selectedFolderIds.removeAll()
                            } else {
                                isSelecting = true
                            }
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isEditing {
                        Menu {
                            Button(action: {
                                HapticManager.impact(.light)
                                showFileImporter = true
                            }) {
                                Label("Import Files", systemImage: "doc.badge.plus")
                            }
                            Button(action: {
                                HapticManager.impact(.light)
                                showNewFolderSheet = true
                            }) {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add")
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if isEditing {
                        if !selectableFolderIds.isEmpty {
                            Button(action: {
                                HapticManager.impact(.light)
                                toggleSelectAll()
                            }) {
                                Label(isAllSelected ? "Deselect All" : "Select All", systemImage: isAllSelected ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.check")
                            }
                            Spacer()
                        }
                        if !selectedFolderIds.isEmpty {
                             Button {
                                 HapticManager.impact(.light)
                                 showBulkMoveSheet = true
                             } label: {
                                 Label("Merge", systemImage: "folder")
                             }
                            Spacer()
                            Button(role: .destructive) {
                                 HapticManager.impact(.heavy)
                                 HapticManager.notification(.warning)
                                 showBulkDeleteSheet = true
                             } label: {
                                 Label("Delete", systemImage: "trash")
                             }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .preferredColorScheme(sheetColorScheme)
            }
            .sheet(isPresented: $showNewFolderSheet) {
                NewFolderSheet(onSave: { name in
                    createFolder(name: name)
                })
            }
            .sheet(isPresented: $showFolderSelection) {
                FolderSelectionSheet(
                    folders: folders,
                    selectedFolder: $selectedFolderForImport,
                    onSave: {
                        if let folder = selectedFolderForImport {
                            importToFolder(folder)
                        }
                    }
                )
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: SupportedFormats.voiceBoxAudioTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    pendingImportURLs = urls
                    showFolderSelection = true
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    showImportError = true
                }
            }
            .alert("Import Result", isPresented: $showImportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importErrorMessage)
            }
            .alert("Library Error", isPresented: $showLibraryError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(libraryErrorMessage)
            }
            .alert("Rename Folder", isPresented: $showRenameAlert) {
                TextField("Folder name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    folderToRename = nil
                }
                Button("Rename") {
                    HapticManager.impact(.light)
                    HapticManager.notification(.success)
                    guard let folder = folderToRename else { return }
                    let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty else { return }
                    let newName = uniqueFolderName(for: trimmedName, excluding: folder.id)
                    if folder.name != newName {
                        folder.name = newName
                        do {
                            try modelContext.save()
                        } catch {
                            presentError("Failed to rename folder", error: error)
                        }
                    }
                    folderToRename = nil
                }
            }
            .alert("Delete Folder", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    folderToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    HapticManager.impact(.heavy)
                    HapticManager.notification(.success)
                    guard let folder = folderToDelete else { return }
                    if let unfiled = unfiledFolder {
                        for book in folder.books {
                            book.folder = unfiled
                        }
                    }
                    modelContext.delete(folder)
                    do {
                        try modelContext.save()
                    } catch {
                        presentError("Failed to delete folder", error: error)
                    }
                    folderToDelete = nil
                }
            } message: {
                Text("This will move all books in this folder to Unfiled. Continue?")
            }
            .overlay {
                if importService.isImporting {
                    ImportProgressOverlay(importService: importService) {
                        importService.cancelImport()
                    }
                }
            }
            .onAppear {
                ensureUnfiledFolderExists()
                updateCachedUnfiledFolder()
            }
            .onChange(of: folders.map(\.id)) { _, _ in
                updateCachedUnfiledFolder()
                selectedFolderIds = selectedFolderIds.intersection(selectableFolderIds)
            }
            .onDisappear {
                importTask?.cancel()
                retryTask?.cancel()
            }
    .sheet(isPresented: $showBulkMoveSheet) {
        BulkMoveFoldersSheet(
            folderIds: selectedFolderIds,
            folders: folders,
            onSave: { targetFolder in
                moveSelectedFolders(to: targetFolder)
                selectedFolderIds.removeAll()
                showBulkMoveSheet = false
            },
            onCancel: {
                showBulkMoveSheet = false
            }
        )
    }
    .sheet(isPresented: $showBulkDeleteSheet) {
        BulkDeleteFoldersConfirmationSheet(
            count: selectedFolderIds.count,
            onConfirm: {
                deleteSelectedFolders()
                selectedFolderIds.removeAll()
                showBulkDeleteSheet = false
            },
            onCancel: {
                showBulkDeleteSheet = false
            }
        )
    }
    .sheet(item: $folderToMerge) { folder in
        MergeFolderSheet(
            sourceFolder: folder,
            folders: folders,
            onSave: { targetFolder in
                mergeFolder(folder, to: targetFolder)
                folderToMerge = nil
            },
            onCancel: {
                folderToMerge = nil
            }
        )
    }
    .sheet(item: $searchBookToMove) { book in
        MoveToFolderSheet(
            book: book,
            folders: folders,
            onSave: { targetFolder in
                book.folder = targetFolder
                do {
                    try modelContext.save()
                } catch {
                    presentError("Failed to move book", error: error)
                }
                searchBookToMove = nil
            },
            onCancel: {
                searchBookToMove = nil
            }
        )
    }
    .alert("Delete Book", isPresented: $showSearchBookDeleteConfirmation) {
        Button("Cancel", role: .cancel) {
            searchBookToDelete = nil
        }
        Button("Delete", role: .destructive) {
            if let book = searchBookToDelete {
                let audioURL = StorageManager.shared.storyCastLibraryURL
                    .appendingPathComponent(book.localFileName)
                try? FileManager.default.removeItem(at: audioURL)
                if let coverArt = book.coverArtFileName {
                    Task { await StorageManager.shared.deleteCoverArt(fileName: coverArt) }
                }
                modelContext.delete(book)
                do {
                    try modelContext.save()
                } catch {
                    presentError("Failed to delete book", error: error)
                }
            }
            searchBookToDelete = nil
        }
    } message: {
        Text("Are you sure you want to delete \"\(searchBookToDelete?.title ?? "this book")\"?")
    }
        }
    }
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Books", systemImage: "books.vertical")
        } description: {
            Text("Import books to get started")
        } actions: {
            Button(action: {
                showFileImporter = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Import Files")
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var folderSection: some View {
        Group {
            if unfiledFolder != nil || !userFolders.isEmpty {
                Section {
                    if let unfiled = unfiledFolder {
                        folderRowView(unfiled)
                    }

                    ForEach(userFolders) { folder in
                        folderRowView(folder)
                    }
                    .onDelete(perform: isEditing ? nil : deleteUserFolders as ((IndexSet) -> Void)?)
                } header: {
                    Text("Folders")
                }
            }
        }
    }

    private var searchResultsSection: some View {
        Group {
            if filteredFolders.isEmpty && filteredBooks.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different search term")
                }
            } else {
                if !filteredFolders.isEmpty {
                    Section {
                        ForEach(filteredFolders) { folder in
                            folderRowView(folder)
                        }
                    } header: {
                        Text("Folders")
                    }
                }

                if !filteredBooks.isEmpty {
                    Section {
                        ForEach(filteredBooks) { book in
                            BookRowView(
                                book: book,
                                onMove: {
                                    searchBookToMove = book
                                },
                                onDelete: {
                                    searchBookToDelete = book
                                    showSearchBookDeleteConfirmation = true
                                }
                            )
                        }
                    } header: {
                        Text("Books")
                    }
                }
            }
        }
    }
    
    private func deleteUserFolders(offsets: IndexSet) {
        ensureUnfiledFolderExists()
        updateCachedUnfiledFolder()
        let destinationFolder = unfiledFolder
        let foldersToDelete: [Folder] = offsets.compactMap { index in
            guard userFolders.indices.contains(index) else { return nil }
            return userFolders[index]
        }
        withAnimation {
            for folder in foldersToDelete {
                if let destinationFolder {
                    for book in folder.books {
                        book.folder = destinationFolder
                    }
                }
                modelContext.delete(folder)
            }
            do {
                try modelContext.save()
            } catch {
                presentError("Failed to delete folders", error: error)
            }
        }
    }

    private func mergeFolder(_ folder: Folder) {
        folderToMerge = folder
    }

    private func mergeFolder(_ sourceFolder: Folder, to targetFolder: Folder) {
        for book in sourceFolder.books {
            book.folder = targetFolder
        }
        modelContext.delete(sourceFolder)
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to merge folder", error: error)
        }
    }
    
    private var failedImportsSection: some View {
        Group {
            if !importService.failedImports.isEmpty {
                Section {
                    ForEach(Array(importService.failedImports)) { failed in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failed.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(failed.errorType.userMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(failed.fileName)")
                            .accessibilityValue(failed.errorType.userMessage)
                            
                            Spacer()

                            if failed.errorType != .unsupportedFormat && failed.errorType != .drmProtected {
                                Button(action: {
                                    retryTask?.cancel()
                                    retryTask = Task {
                                        await importService.retryImport(failed, container: modelContext.container)
                                    }
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Retry import for \(failed.fileName)")
                                .accessibilityHint("Attempts this import again")
                            }
                            
                            Button(action: {
                                importService.dismissFailedImport(failed)
                            }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Dismiss failed import for \(failed.fileName)")
                            .accessibilityHint("Removes this error from the list")
                        }
                    }
                } header: {
                    HStack {
                        Text("Failed Imports")
                        Spacer()
                        if importService.failedImports.contains(where: { $0.errorType.isTransient }) {
                            Button("Retry All") {
                                retryTask?.cancel()
                                retryTask = Task {
                                    await importService.retryAllFailed(container: modelContext.container)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
    
    /// ContentView.ensureUnfiledFolderExists(container:) guarantees the Unfiled
    /// folder is created before LibraryView ever appears, so we only need a
    /// read-side guard here — no creation logic.
    private func ensureUnfiledFolderExists() {
        guard !folders.contains(where: { $0.isSystem }) else { return }
        // Unfiled folder should already exist from ContentView initialization.
        // Log a warning if it's missing — this would indicate a logic error elsewhere.
        AppLogger.ui.warning("ensureUnfiledFolderExists: Unfiled folder not found in @Query results; it should have been created by ContentView.")
    }

    private func updateCachedUnfiledFolder() {
        cachedUnfiledFolder = folders.first { $0.isSystem }
    }

    private func createFolder(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let sortOrder = (userFolders.map { $0.sortOrder }.max() ?? 0) + 1
        let folderName = uniqueFolderName(for: trimmedName)
        let folder = Folder(name: folderName, isSystem: false, sortOrder: sortOrder)
        modelContext.insert(folder)
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to create folder", error: error)
        }
    }

    private func renameFolder(_ folder: Folder) {
        folderToRename = folder
        renameText = folder.name
        showRenameAlert = true
    }

    private func deleteFolder(_ folder: Folder) {
        folderToDelete = folder
        showDeleteConfirmation = true
    }

    private func uniqueFolderName(for name: String, excluding folderId: UUID? = nil) -> String {
        let candidateFolders = folders.filter { $0.id != folderId }
        let existingNames = Set(candidateFolders.map { $0.name })

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

    private func moveSelectedFolders(to targetFolder: Folder) {
        for folderId in selectedFolderIds {
            if let folder = folders.first(where: { $0.id == folderId }), !folder.isSystem {
                for book in folder.books {
                    book.folder = targetFolder
                }
                modelContext.delete(folder)
            }
        }
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to merge folders", error: error)
        }
    }

    private func deleteSelectedFolders() {
        for folderId in selectedFolderIds {
            if let folder = folders.first(where: { $0.id == folderId }), !folder.isSystem {
                if let unfiled = unfiledFolder {
                    for book in folder.books {
                        book.folder = unfiled
                    }
                }
                modelContext.delete(folder)
            }
        }
        do {
            try modelContext.save()
        } catch {
            presentError("Failed to delete folders", error: error)
        }
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

    private func deduplicatedSearchBooks(_ books: [Book]) -> [Book] {
        var seenKeys = Set<String>()
        var deduplicatedBooks: [Book] = []

        for book in books {
            let normalizedTitle = book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedAuthor = (book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let roundedDuration = Int(book.duration.rounded())
            let deduplicationKey = "\(normalizedTitle)|\(normalizedAuthor)|\(roundedDuration)"

            if seenKeys.insert(deduplicationKey).inserted {
                deduplicatedBooks.append(book)
            }
        }

        return deduplicatedBooks
    }

    private func folderRowView(_ folder: Folder) -> some View {
        FolderRowView(
            folder: folder,
            isEditing: isEditing,
            isSelected: selectedFolderIds.contains(folder.id),
            onSelect: {
                if !isSelecting {
                    isSelecting = true
                }
                guard !folder.isSystem else { return }
                if selectedFolderIds.contains(folder.id) {
                    selectedFolderIds.remove(folder.id)
                } else {
                    selectedFolderIds.insert(folder.id)
                }
            },
            onRename: { renameFolder(folder) },
            onDelete: { deleteFolder(folder) },
            onMove: { mergeFolder(folder) }
        )
    }

    private func importToFolder(_ folder: Folder) {
        selectedFolderForImport = nil
        importTask?.cancel()
        importTask = Task {
            await importService.importFilesToFolder(urls: pendingImportURLs, folderId: folder.id, container: modelContext.container)
            guard !Task.isCancelled else { return }
            pendingImportURLs = []
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

    private func presentError(_ message: String, error: Error) {
        libraryErrorMessage = "\(message): \(error.localizedDescription)"
        showLibraryError = true
    }

}

#Preview {
    LibraryView()
        .modelContainer(for: [Book.self, Chapter.self, Folder.self], inMemory: true)
        .environmentObject(ImportService.shared)
}
