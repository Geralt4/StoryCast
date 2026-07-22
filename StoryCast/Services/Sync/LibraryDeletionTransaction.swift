import Foundation
import SwiftData

/// Stages model deletion, sync sidecar removal, tombstone work, and deferred
/// filesystem cleanup in one caller-owned `ModelContext` transaction.
@MainActor
enum LibraryDeletionTransaction {
    static func stageBookDeletion(
        _ book: Book,
        deviceID: String?,
        in context: ModelContext
    ) throws {
        var pendingCleanups = Set<PendingFileCleanup>()

        if book.isRemote {
            if let cachePath = book.localCachePath {
                pendingCleanups.insert(PendingFileCleanup(
                    location: .remoteAudioCache,
                    relativePath: cachePath
                ))
            }
        } else {
            pendingCleanups.formUnion(try SyncController.shared.stageDeletion(
                entityKind: .book,
                entityID: book.id.uuidString,
                deviceID: deviceID,
                in: context
            ))
            if !book.localFileName.isEmpty {
                pendingCleanups.insert(PendingFileCleanup(
                    location: .managedLibrary,
                    relativePath: book.localFileName
                ))
            }
        }

        if let coverArtFileName = book.coverArtFileName {
            pendingCleanups.insert(PendingFileCleanup(
                location: book.isRemote ? .remoteCoverArt : .coverArt,
                relativePath: coverArtFileName
            ))
        }

        for cleanup in pendingCleanups {
            _ = try StorageCleanupCoordinator.stage(
                location: cleanup.location,
                relativePath: cleanup.relativePath,
                in: context
            )
        }
        context.delete(book)
    }

    static func stageFolderDeletion(
        id: UUID,
        deviceID: String?,
        in context: ModelContext
    ) throws {
        _ = try SyncController.shared.stageDeletion(
            entityKind: .folder,
            entityID: id.uuidString,
            deviceID: deviceID,
            in: context
        )
    }
}
