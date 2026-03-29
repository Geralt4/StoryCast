import Foundation
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Book.title) private var allBooks: [Book]
    @EnvironmentObject private var importService: ImportService
    @State private var searchHandler = LibrarySearchHandler()
    @State private var importHandler = LibraryImportHandler()
    @State private var coordinator = LibraryViewCoordinator()
    @State private var actionTask: Task<Void, Never>?
    @State private var showLibraryError = false
    @State private var libraryErrorMessage = ""
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.automatic.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var folderOperations: LibraryFolderOperations { LibraryFolderOperations(modelContext: modelContext) }
    private var bookActions: LibraryBookActions { LibraryBookActions(modelContext: modelContext) }
    private var sheetColorScheme: ColorScheme? {
        let mode = AppearanceMode(rawValue: appearanceModeRaw) ?? .automatic
        return mode == .automatic ? systemColorScheme : mode.colorScheme
    }
    private var isEditing: Bool { coordinator.isEditing }
    private var unfiledFolder: Folder? { folders.first { $0.isSystem } }
    private var userFolders: [Folder] { folders.filter { !$0.isSystem } }
    private var hasAnyContent: Bool { !allBooks.isEmpty || !userFolders.isEmpty }
    private var selectableFolderIds: Set<UUID> { Set(userFolders.map { $0.id }) }
    private var isAllSelected: Bool { !selectableFolderIds.isEmpty && coordinator.selectedFolderIds.isSuperset(of: selectableFolderIds) }
    private var filteredFolders: [Folder] { searchHandler.getFilteredFolders(allFolders: folders) }
    private var filteredBooks: [Book] { searchHandler.getFilteredBooks(allBooks: allBooks) }

    var body: some View {
        NavigationStack {
            List {
                if searchHandler.isSearching { searchResultsSection }
                else if !hasAnyContent { emptyStateView }
                else { folderSection; failedImportsSection }
            }
            .navigationDestination(for: Folder.self) { FolderDetailView(folder: $0) }
            .navigationDestination(for: Book.self) { PlayerView(book: $0) }
            .navigationTitle("Library")
            .searchable(text: $searchHandler.searchText, prompt: "Search library")
            .onChange(of: searchHandler.searchText) { _, _ in searchHandler.updateSearchText(searchHandler.searchText, folders: folders, books: allBooks) }
            .toolbar { leadingToolbar }
            .toolbar { trailingToolbar }
            .toolbar { bottomToolbar }
            .sheet(isPresented: $coordinator.showSettings) { SettingsView().preferredColorScheme(sheetColorScheme) }
            .sheet(isPresented: $coordinator.showNewFolderSheet) { NewFolderSheet(onSave: { _ = folderOperations.createFolder(name: $0) }) }
            .sheet(isPresented: $coordinator.showFolderSelection) {
                FolderSelectionSheet(folders: folders, selectedFolder: $coordinator.selectedFolderForImport, onSave: {
                    if let folder = coordinator.selectedFolderForImport {
                        importHandler.importFiles(coordinator.pendingImportURLs, to: folder, importService: importService, modelContext: modelContext)
                    }
                    coordinator.completeFolderImportSelection()
                })
            }
            .fileImporter(isPresented: $coordinator.showFileImporter, allowedContentTypes: SupportedFormats.voiceBoxAudioTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): coordinator.queueImports(urls)
                case .failure(let error): importHandler.importErrorMessage = error.localizedDescription; importHandler.showImportError = true
                }
            }
            .alert("Import Result", isPresented: $importHandler.showImportError) { Button("OK", role: .cancel) { } } message: { Text(importHandler.importErrorMessage) }
            .alert("Library Error", isPresented: $showLibraryError) { Button("OK", role: .cancel) { } } message: { Text(libraryErrorMessage) }
            .alert("Rename Folder", isPresented: $coordinator.showRenameAlert) {
                TextField("Folder name", text: $coordinator.renameText)
                Button("Cancel", role: .cancel) { coordinator.finishFolderRename() }
                Button("Rename") {
                    HapticManager.impact(.light); HapticManager.notification(.success)
                    if let folder = coordinator.folderToRename { folderOperations.renameFolder(folder, newName: coordinator.renameText) }
                    coordinator.finishFolderRename()
                }
            }
            .alert("Delete Folder", isPresented: $coordinator.showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { coordinator.finishFolderDeletion() }
                Button("Delete", role: .destructive) {
                    HapticManager.impact(.heavy); HapticManager.notification(.success)
                    if let folder = coordinator.folderToDelete, let unfiled = unfiledFolder {
                        folderOperations.deleteFolderWithDestination(folder, destination: unfiled)
                    } else {
                        AppLogger.app.error("LibraryView: cannot delete folder — unfiledFolder is nil")
                    }
                    coordinator.finishFolderDeletion()
                }
            } message: { Text("This will move all books in this folder to Unfiled. Continue?") }
            .overlay { if importService.isImporting { ImportProgressOverlay(importService: importService) { importHandler.cancelImport(importService: importService) } } }
            .sheet(isPresented: $coordinator.showBulkMoveSheet) {
                BulkMoveFoldersSheet(folderIds: coordinator.selectedFolderIds, folders: folders, onSave: { targetFolder in
                    folderOperations.moveFolders(coordinator.selectedFolderIds, into: targetFolder)
                    coordinator.selectedFolderIds.removeAll(); coordinator.showBulkMoveSheet = false
                }, onCancel: { coordinator.showBulkMoveSheet = false })
            }
            .sheet(isPresented: $coordinator.showBulkDeleteSheet) {
                BulkDeleteFoldersConfirmationSheet(count: coordinator.selectedFolderIds.count, onConfirm: {
                    folderOperations.deleteFolders(coordinator.selectedFolderIds)
                    coordinator.selectedFolderIds.removeAll(); coordinator.showBulkDeleteSheet = false
                }, onCancel: { coordinator.showBulkDeleteSheet = false })
            }
            .sheet(item: $coordinator.folderToMerge) { folder in
                MergeFolderSheet(sourceFolder: folder, folders: folders, onSave: { targetFolder in
                    folderOperations.mergeFolder(folder, into: targetFolder); coordinator.folderToMerge = nil
                }, onCancel: { coordinator.folderToMerge = nil })
            }
            .sheet(item: $coordinator.searchBookToMove) { book in
                MoveToFolderSheet(book: book, folders: folders, onSave: { targetFolder in
                    do { try bookActions.moveBook(book, to: targetFolder); coordinator.finishSearchBookMove() }
                    catch { presentLibraryError("Failed to move book", error: error) }
                }, onCancel: { coordinator.finishSearchBookMove() })
            }
            .alert("Delete Book", isPresented: $coordinator.showSearchBookDeleteConfirmation) {
                Button("Cancel", role: .cancel) { coordinator.finishSearchBookDeletion() }
                Button("Delete", role: .destructive) {
                    guard let book = coordinator.searchBookToDelete else { return }
                    coordinator.finishSearchBookDeletion(); deleteSearchBook(book)
                }
            } message: { Text("Are you sure you want to delete \"\(coordinator.searchBookToDelete?.title ?? "this book")\"?") }
            .onDisappear { actionTask?.cancel(); importHandler.onDisappear(); searchHandler.onDisappear() }
        }
    }

    private var leadingToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { HapticManager.impact(.light); coordinator.showSettings = true } label: { Image(systemName: "gear") }.accessibilityLabel("Settings")
        }
    }

    private var trailingToolbar: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Done" : "Select") { HapticManager.impact(.light); withAnimation { coordinator.toggleSelectionMode() } }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isEditing {
                    Menu {
                        Button { HapticManager.impact(.light); coordinator.showFileImporter = true } label: { Label("Import Files", systemImage: "doc.badge.plus") }
                        Button { HapticManager.impact(.light); coordinator.showNewFolderSheet = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                }
            }
        }
    }

    @ToolbarContentBuilder private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if isEditing {
                if !selectableFolderIds.isEmpty {
                    Button { HapticManager.impact(.light); coordinator.toggleSelectAll(selectableFolderIds: selectableFolderIds) } label: {
                        Label(isAllSelected ? "Deselect All" : "Select All", systemImage: isAllSelected ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.check")
                    }
                    Spacer()
                }
                if !coordinator.selectedFolderIds.isEmpty {
                    Button { HapticManager.impact(.light); coordinator.showBulkMoveSheet = true } label: { Label("Merge", systemImage: "folder") }
                    Spacer()
                    Button(role: .destructive) { HapticManager.impact(.heavy); HapticManager.notification(.warning); coordinator.showBulkDeleteSheet = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Books", systemImage: "books.vertical")
        } description: {
            Text("Import books to get started")
        } actions: {
            Button { coordinator.showFileImporter = true } label: { HStack(spacing: 6) { Image(systemName: "plus"); Text("Import Files") } }.buttonStyle(.borderedProminent)
        }
    }

    private var folderSection: some View {
        Group {
            if unfiledFolder != nil || !userFolders.isEmpty {
                Section {
                    if let unfiled = unfiledFolder { folderRowView(unfiled) }
                    ForEach(userFolders) { folderRowView($0) }.onDelete(perform: isEditing ? nil : deleteUserFolders as ((IndexSet) -> Void)?)
                } header: { Text("Folders") }
            }
        }
    }

    private var searchResultsSection: some View {
        Group {
            if filteredFolders.isEmpty && filteredBooks.isEmpty {
                ContentUnavailableView { Label("No Results", systemImage: "magnifyingglass") } description: { Text("Try a different search term") }
            } else {
                if !filteredFolders.isEmpty { Section { ForEach(filteredFolders) { folderRowView($0) } } header: { Text("Folders") } }
                if !filteredBooks.isEmpty {
                    Section {
                        ForEach(filteredBooks) { book in
                            BookRowView(book: book, onMove: { coordinator.beginSearchBookMove(book) }, onDelete: { coordinator.beginSearchBookDeletion(book) },
                                onDownload: { bookActions.downloadBook(book) }, onRemoveDownload: { bookActions.removeDownloadedBook(book) })
                        }
                    } header: { Text("Books") }
                }
            }
        }
    }

    private var failedImportsSection: some View {
        Group {
            if !importService.failedImports.isEmpty {
                Section {
                    ForEach(Array(importService.failedImports)) { failed in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failed.fileName).font(.subheadline).lineLimit(1)
                                Text(failed.errorType.userMessage).font(.caption).foregroundColor(.red)
                            }.accessibilityElement(children: .combine).accessibilityLabel("\(failed.fileName)").accessibilityValue(failed.errorType.userMessage)
                            Spacer()
                            if failed.errorType != .unsupportedFormat && failed.errorType != .drmProtected {
                                Button { importHandler.retryImport(failed, importService: importService, modelContext: modelContext) } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.borderless).accessibilityLabel("Retry import for \(failed.fileName)")
                            }
                            Button { importHandler.dismissFailedImport(failed, importService: importService) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).foregroundColor(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Failed Imports")
                        Spacer()
                        if importService.failedImports.contains(where: { $0.errorType.isTransient }) {
                            Button("Retry All") { importHandler.retryAllFailed(importService: importService, modelContext: modelContext) }.font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func folderRowView(_ folder: Folder) -> some View {
        FolderRowView(folder: folder, isEditing: isEditing, isSelected: coordinator.selectedFolderIds.contains(folder.id),
            onSelect: { coordinator.selectFolder(folder) }, onRename: { coordinator.beginFolderRename(folder) },
            onDelete: { coordinator.beginFolderDeletion(folder) }, onMove: { coordinator.folderToMerge = folder })
    }

    private func deleteSearchBook(_ book: Book) {
        actionTask?.cancel()
        actionTask = Task { do { try await bookActions.deleteBook(book) } catch { presentLibraryError("Failed to delete book", error: error) } }
    }

    private func deleteUserFolders(offsets: IndexSet) {
        guard let destinationFolder = unfiledFolder else { return }
        let foldersToDelete = offsets.compactMap { userFolders.indices.contains($0) ? userFolders[$0] : nil }
        withAnimation { for folder in foldersToDelete { folderOperations.deleteFolderWithDestination(folder, destination: destinationFolder) } }
    }

    private func presentLibraryError(_ message: String, error: Error) {
        libraryErrorMessage = "\(message): \(error.localizedDescription)"; showLibraryError = true
    }
}

#if DEBUG
struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView().modelContainer(for: [Book.self, Chapter.self, Folder.self], inMemory: true).environmentObject(ImportService.shared)
    }
}
#endif