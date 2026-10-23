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

    /// Resolves or inserts Unfiled without saving. Use this while applying a
    /// larger transaction that must commit its folder creation atomically.
    static func stageUnfiledFolder(in context: ModelContext) throws -> Folder {
        var fetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.isSystem })
        fetch.fetchLimit = 1
        if let existing = try context.fetch(fetch).first {
            return existing
        }

        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(folder)
        return folder
    }

    /// Resolves or creates the folder that holds a server's books.
    ///
    /// The folder reuses the server's UUID as its own `id`, so it can be told
    /// apart from user folders without a schema change (see `serverFolderIDs`).
    /// Saves nothing; the caller commits together with the books.
    static func resolveServerFolder(serverId: UUID, name: String, in context: ModelContext) throws -> Folder {
        var fetch = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == serverId })
        fetch.fetchLimit = 1
        if let existing = try context.fetch(fetch).first {
            return existing
        }

        let folders = try context.fetch(FetchDescriptor<Folder>())
        let existingNames = Set(folders.map(\.name))
        let baseName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var folderName = baseName.isEmpty ? "Audiobookshelf" : baseName
        var counter = 2
        let uniqueBase = folderName
        while existingNames.contains(folderName) {
            folderName = "\(uniqueBase) (\(counter))"
            counter += 1
        }

        let sortOrder = (folders.filter { !$0.isSystem }.map(\.sortOrder).max() ?? 0) + 1
        let folder = Folder(id: serverId, name: folderName, isSystem: false, sortOrder: sortOrder)
        context.insert(folder)
        return folder
    }

    /// IDs of every configured Audiobookshelf server. A folder whose id is in
    /// this set is managed by that server's sync.
    static func serverFolderIDs(in context: ModelContext) -> Set<UUID> {
        let servers = (try? context.fetch(FetchDescriptor<ABSServer>())) ?? []
        return Set(servers.map(\.id))
    }
}
