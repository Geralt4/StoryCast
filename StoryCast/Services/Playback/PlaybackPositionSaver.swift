import Foundation
import SwiftData
import os

/// Saves the player's position into the book it belongs to when the app leaves
/// the foreground or an interruption asks for it.
@MainActor
enum PlaybackPositionSaver {
    static func saveCurrentPosition(container: ModelContainer) {
        let player = AudioPlayerService.shared
        guard player.currentURL != nil || player.currentBookID != nil else { return }
        let currentTime = player.currentTime
        guard currentTime.isFinite, currentTime >= 0 else { return }

        // A separate ModelContext is required because the App struct has no
        // environment context. Only one property is written, then saved.
        let context = ModelContext(container)

        do {
            guard let match = try currentBook(in: context, player: player) else { return }
            match.book.lastPlaybackPosition = currentTime
            try context.save()
            // Streaming progress goes to the server through the play session.
            guard !match.isStreamingSession else { return }

            let bookID = match.book.id
            Task {
                await SyncController.shared.recordProgress(
                    bookID: bookID,
                    position: currentTime,
                    actionKind: "background",
                    container: container
                )
            }
            // Clear any existing UserDefaults backup after successful save
            UserDefaults.standard.removeObject(forKey: backupKey(for: bookID))
        } catch {
            AppLogger.app.error("Failed to save playback position: \(error.localizedDescription, privacy: .private)")
            // Roll back the failed context before doing any further fetches:
            // the context may hold uncommitted mutations from the previous
            // (failed) save that would otherwise influence the next fetch.
            context.rollback()
            guard let match = try? currentBook(in: context, player: player),
                  !match.isStreamingSession else {
                // Remote streams are backed up by ProgressBackupStore instead.
                return
            }
            let backup: [String: Any] = [
                "currentTime": currentTime,
                "timestamp": Date().timeIntervalSince1970
            ]
            UserDefaults.standard.set(backup, forKey: backupKey(for: match.book.id))
            AppLogger.app.debug("Backed up playback position to UserDefaults: \(currentTime)s")
        }
    }

    private static func backupKey(for bookID: UUID) -> String {
        "localBookPosition_\(bookID.uuidString)"
    }

    /// Finds the book being played: by the player's book ID first, then by the
    /// active remote session, then by matching the file name of older loads.
    private static func currentBook(
        in context: ModelContext,
        player: AudioPlayerService
    ) throws -> (book: Book, isStreamingSession: Bool)? {
        let session = PlaybackSessionManager.shared

        if let bookID = player.currentBookID {
            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
            descriptor.fetchLimit = 1
            if let book = try context.fetch(descriptor).first {
                let isStreaming = book.isRemote
                    && session.activeRemoteItemId != nil
                    && book.remoteItemId == session.activeRemoteItemId
                return (book, isStreaming)
            }
        }

        if let remoteItemId = session.activeRemoteItemId {
            let activeServerID = session.activeRemoteServerID
            // O(n) fetch-and-filter is acceptable here because this runs
            // infrequently (on background/inactive scene phase) and the
            // predicate would need to compare optional properties which
            // SwiftData's #Predicate has limited support for.
            let books = try context.fetch(FetchDescriptor<Book>())
            if let book = books.first(where: { book in
                book.remoteItemId == remoteItemId && (activeServerID == nil || book.serverId == activeServerID)
            }) {
                return (book, true)
            }
        }

        guard let currentURL = player.currentURL else { return nil }
        let fileName = currentURL.lastPathComponent
        // Standardize both URLs so path differences (trailing slashes,
        // symlink resolution) don't cause a false mismatch.
        let isRemoteCache = currentURL.deletingLastPathComponent().standardizedFileURL
            == StorageManager.shared.remoteAudioCacheDirectoryURL.standardizedFileURL
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { book in
            isRemoteCache ? book.localCachePath == fileName : book.localFileName == fileName
        })
        descriptor.fetchLimit = 1
        guard let book = try context.fetch(descriptor).first else { return nil }
        return (book, false)
    }
}
