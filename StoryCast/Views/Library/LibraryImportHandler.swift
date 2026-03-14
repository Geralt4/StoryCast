import Foundation
import SwiftData

/// Handles import coordination and error presentation for the library view.
///
/// `LibraryImportHandler` manages:
/// - Import file coordination
/// - Import error presentation
/// - Import retry coordination
/// - Import progress observation
///
/// ## Usage
///
/// ```swift
/// @State private var importHandler = LibraryImportHandler()
/// importHandler.importFiles(urls, to: folder, importService: importService, modelContext: modelContext)
/// if importHandler.showImportError { ... }
/// ```
@MainActor
@Observable
final class LibraryImportHandler {
    /// Whether to show the import error alert.
    var showImportError = false
    
    /// The message to display in the import error alert.
    var importErrorMessage = ""
    
    /// Task for managing ongoing import operations.
    private var importTask: Task<Void, Never>?
    
    /// Task for managing retry operations.
    private var retryTask: Task<Void, Never>?
    
    init() {}
    
    /// Imports files to the specified folder.
    ///
    /// - Parameters:
    ///   - urls: File URLs to import
    ///   - folder: Destination folder
    ///   - importService: The import service to use
    ///   - modelContext: The model context for database operations
    func importFiles(_ urls: [URL], to folder: Folder, importService: ImportService, modelContext: ModelContext) {
        importTask?.cancel()
        
        importTask = Task {
            await importService.importFilesToFolder(
                urls: urls,
                folderId: folder.id,
                container: modelContext.container
            )
            
            guard !Task.isCancelled else { return }
            
            presentImportResult(importService: importService)
        }
    }
    
    /// Presents the import result, showing errors if any occurred.
    ///
    /// - Parameter importService: The import service to check for results.
    func presentImportResult(importService: ImportService) {
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
    
    /// Retries a failed import.
    ///
    /// - Parameters:
    ///   - failedImport: The failed import to retry
    ///   - importService: The import service to use
    ///   - modelContext: The model context for database operations
    func retryImport(_ failedImport: FailedImport, importService: ImportService, modelContext: ModelContext) {
        retryTask?.cancel()
        
        retryTask = Task {
            await importService.retryImport(failedImport, container: modelContext.container)
        }
    }
    
    /// Retries all failed imports.
    ///
    /// - Parameters:
    ///   - importService: The import service to use
    ///   - modelContext: The model context for database operations
    func retryAllFailed(importService: ImportService, modelContext: ModelContext) {
        retryTask?.cancel()
        
        retryTask = Task {
            await importService.retryAllFailed(container: modelContext.container)
        }
    }
    
    /// Dismisses a failed import from the list.
    ///
    /// - Parameters:
    ///   - failedImport: The failed import to dismiss
    ///   - importService: The import service to update
    func dismissFailedImport(_ failedImport: FailedImport, importService: ImportService) {
        importService.dismissFailedImport(failedImport)
    }
    
    /// Cancels any ongoing import.
    ///
    /// - Parameter importService: The import service to cancel
    func cancelImport(importService: ImportService) {
        importService.cancelImport()
    }
    
    /// Cleans up tasks when view disappears.
    func onDisappear() {
        importTask?.cancel()
        importTask = nil
        retryTask?.cancel()
        retryTask = nil
    }
}