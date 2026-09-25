import Foundation
import SwiftData
import os

/// What an older single-file download (`<uuid>_remote.<ext>`) really holds.
nonisolated enum LegacyDownloadVerdict: Sendable, Equatable {
    /// The book is one file on the server, so the download is complete.
    case valid
    /// The book has several files on the server: older versions saved only
    /// the first one.
    case truncated
    /// Complete, but saved with the wrong extension (older versions named
    /// every download `.m4b`, including MP3 books).
    case wrongExtension(String)
    /// The server couldn't be asked (offline, logged out); try again later.
    case undetermined
}

/// Audio container recognised from a file's first bytes.
nonisolated enum AudioFileKind: Sendable, Equatable {
    case mp3, mp4, flac, ogg

    var canonicalExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .mp4: return "m4a"
        case .flac: return "flac"
        case .ogg: return "ogg"
        }
    }

    var acceptedExtensions: Set<String> {
        switch self {
        case .mp3: return ["mp3"]
        case .mp4: return ["m4a", "m4b", "mp4", "aac"]
        case .flac: return ["flac"]
        case .ogg: return ["ogg", "oga", "opus"]
        }
    }

    static func sniff(_ header: Data) -> AudioFileKind? {
        let bytes = [UInt8](header.prefix(12))
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return .mp3 } // "ID3"
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return .mp3 }             // MPEG frame sync
        if bytes.count >= 8, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return .mp4 }            // "ftyp"
        if bytes.count >= 4, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] { return .flac }           // "fLaC"
        if bytes.count >= 4, bytes[0...3] == [0x4F, 0x67, 0x67, 0x53] { return .ogg }            // "OggS"
        return nil
    }
}

/// Finds older single-file downloads of books that are several files on the
/// server (so they hold only the first file) and removes them, so the book
/// streams in full or can be downloaded again. A download is only removed
/// after the server confirms the book has more than one file: an offline
/// device never loses its copy.
@MainActor
enum LegacyRemoteDownloadValidator {
    private static let verifiedKeyPrefix = "legacyRemoteDownloadVerified_"

    nonisolated static func verdict(serverTrackCount: Int?, fileKind: AudioFileKind?, fileExtension: String) -> LegacyDownloadVerdict {
        guard let serverTrackCount else { return .undetermined }
        guard serverTrackCount <= 1 else { return .truncated }
        if let fileKind, !fileKind.acceptedExtensions.contains(fileExtension.lowercased()) {
            return .wrongExtension(fileKind.canonicalExtension)
        }
        return .valid
    }

    /// Whether this exact download was confirmed to hold the whole book.
    static func isVerified(bookID: UUID, cachePath: String) -> Bool {
        UserDefaults.standard.string(forKey: verifiedKeyPrefix + bookID.uuidString) == cachePath
    }

    private static func markVerified(bookID: UUID, cachePath: String) {
        UserDefaults.standard.set(cachePath, forKey: verifiedKeyPrefix + bookID.uuidString)
    }

    private static func clearVerified(bookID: UUID) {
        UserDefaults.standard.removeObject(forKey: verifiedKeyPrefix + bookID.uuidString)
    }

    /// Checks every unverified older download once the server can be reached.
    static func runIfNeeded(container: ModelContainer, api: AudiobookshelfAPI = .shared) async {
        let context = ModelContext(container)
        guard let books = try? context.fetch(FetchDescriptor<Book>()),
              let servers = try? context.fetch(FetchDescriptor<ABSServer>()) else { return }
        let serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })

        for book in books where book.isRemote && book.isDownloaded {
            guard let cachePath = book.localCachePath,
                  !RemoteDownloadLayout.isDownloadFolderName(cachePath),
                  !isVerified(bookID: book.id, cachePath: cachePath),
                  let itemID = book.remoteItemId,
                  let serverID = book.serverId,
                  let server = serversByID[serverID] else { continue }
            let verdict = await validate(
                bookID: book.id,
                itemID: itemID,
                cachePath: cachePath,
                baseURL: server.normalizedURL,
                api: api
            )
            apply(verdict, bookID: book.id, expectedCachePath: cachePath, container: container)
        }
    }

    private static func validate(bookID: UUID, itemID: String, cachePath: String, baseURL: String, api: AudiobookshelfAPI) async -> LegacyDownloadVerdict {
        guard let token = await AudiobookshelfAuth.shared.token(for: baseURL) else { return .undetermined }
        let trackCount: Int?
        do {
            let item = try await api.fetchLibraryItem(baseURL: baseURL, token: token, itemId: itemID)
            trackCount = item.media.tracks?.count ?? item.media.numTracks
        } catch {
            AppLogger.storage.debug("Couldn't check download of book \(bookID, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return .undetermined
        }
        let fileURL = StorageManager.shared.remoteAudioCacheURL(for: cachePath)
        let header = await Task.detached(priority: .utility) { () -> Data? in
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        }.value
        let kind = header.flatMap(AudioFileKind.sniff)
        return verdict(serverTrackCount: trackCount, fileKind: kind, fileExtension: (cachePath as NSString).pathExtension)
    }

    static func apply(_ verdict: LegacyDownloadVerdict, bookID: UUID, expectedCachePath: String, container: ModelContainer) {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        descriptor.fetchLimit = 1
        // The book may have been removed, re-downloaded or opened meanwhile.
        guard let book = try? context.fetch(descriptor).first,
              book.isDownloaded, book.localCachePath == expectedCachePath,
              AudioPlayerService.shared.currentBookID != bookID,
              DownloadManager.shared.downloads[bookID]?.isActive != true else { return }

        switch verdict {
        case .undetermined:
            return
        case .valid:
            markVerified(bookID: bookID, cachePath: expectedCachePath)
        case .truncated:
            do {
                _ = try StorageCleanupCoordinator.stage(location: .remoteAudioCache, relativePath: expectedCachePath, in: context)
                book.isDownloaded = false
                book.localCachePath = nil
                try context.save()
                clearVerified(bookID: bookID)
                StorageCleanupCoordinator.drainPendingCleanup(in: context)
                AppLogger.storage.info("Removed incomplete older download of book \(bookID, privacy: .private)")
            } catch {
                context.rollback()
                AppLogger.storage.error("Couldn't remove incomplete download: \(error.localizedDescription, privacy: .private)")
            }
        case .wrongExtension(let ext):
            let renamed = "\(bookID.uuidString)_remote.\(ext)"
            let source = StorageManager.shared.remoteAudioCacheURL(for: expectedCachePath)
            let destination = StorageManager.shared.remoteAudioCacheURL(for: renamed)
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                book.localCachePath = renamed
                try context.save()
                markVerified(bookID: bookID, cachePath: renamed)
            } catch {
                context.rollback()
                try? FileManager.default.moveItem(at: destination, to: source)
                AppLogger.storage.error("Couldn't rename download: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
