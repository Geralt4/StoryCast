import Foundation
import SwiftData

/// Centralized service for folder operations.
/// Ensures atomic resolution and creation of the "Unfiled" system folder.
@MainActor
enum FolderService {
    /// Atomically resolves or creates the "Unfiled" system folder.
    /// Throws if folder creation fails.
    static func resolveUnfiledFolder(in context: ModelContext) throws -> Folder {
        var fetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        fetch.fetchLimit = 1
        if let existing = try context.fetch(fetch).first {
            return existing
        }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(folder)
        try context.save()
        return folder
    }
}