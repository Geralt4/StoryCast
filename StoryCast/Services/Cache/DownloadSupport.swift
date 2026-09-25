import Foundation
import os

// MARK: - Task tag

/// Identifies the book file a background download task belongs to. It is
/// stored in `URLSessionTask.taskDescription`, which survives the app being
/// terminated, so tasks can be matched to their book after a relaunch.
nonisolated struct DownloadTaskTag: Codable, Sendable, Hashable {
    static let currentVersion = 1

    let v: Int
    let bookId: UUID
    /// The download attempt; files from an older attempt are never accepted.
    let attempt: UUID
    let trackIndex: Int
    let ino: String?
    let ext: String

    init(bookId: UUID, attempt: UUID, trackIndex: Int, ino: String?, ext: String) {
        self.v = Self.currentVersion
        self.bookId = bookId
        self.attempt = attempt
        self.trackIndex = trackIndex
        self.ino = ino
        self.ext = ext
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    /// Nil for tasks created by older versions (whose description was just a
    /// file extension) and for anything malformed.
    static func decode(_ taskDescription: String?) -> DownloadTaskTag? {
        guard let taskDescription, taskDescription.hasPrefix("{"),
              let tag = try? JSONDecoder().decode(DownloadTaskTag.self, from: Data(taskDescription.utf8)),
              tag.v == currentVersion, tag.trackIndex >= 0,
              RemoteDownloadPlanner.isSafeExtension(tag.ext) else { return nil }
        return tag
    }
}

// MARK: - Failures

nonisolated enum DownloadFailure: Error, Sendable, Equatable, LocalizedError {
    case serverUnreachable
    case unauthorized
    case forbidden
    case notFound
    case serverError(Int)
    case fileTooLarge
    case fileChangedOnServer
    case diskFull
    case interrupted
    case invalidResponse
    case untrustedCertificate
    case cancelled
    case other(String)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .serverUnreachable:
            return "The server can't be reached. Check your connection and try again."
        case .unauthorized:
            return "Your Audiobookshelf login has expired. Log in to the server again."
        case .forbidden:
            return "Your Audiobookshelf account isn't allowed to download books."
        case .notFound:
            return "The book was not found on the server."
        case .serverError(let status):
            return "The server reported an error (\(status)). Try again later."
        case .fileTooLarge:
            return "A file in this book is larger than 2 GB and can't be downloaded."
        case .fileChangedOnServer:
            return "The book changed on the server while downloading. Try again."
        case .diskFull:
            return "There isn't enough storage on this device to download the book."
        case .interrupted:
            return "The download was interrupted. Retry to download the remaining parts."
        case .invalidResponse:
            return "The server sent an unexpected response."
        case .untrustedCertificate:
            return "The server's security certificate isn't trusted."
        case .cancelled:
            return "The download was cancelled."
        case .other(let message):
            return message
        }
    }

    static func classify(httpStatus: Int) -> DownloadFailure {
        switch httpStatus {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 500...599: return .serverError(httpStatus)
        default: return .invalidResponse
        }
    }

    static func classify(_ error: Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure { return failure }
        if let apiError = error as? APIError {
            switch apiError {
            case .httpError(statusCode: let status): return classify(httpStatus: status)
            case .unauthorized, .tokenMissing: return .unauthorized
            case .serverUnreachable: return .serverUnreachable
            case .invalidResponse, .decodingError: return .invalidResponse
            case .networkError(let underlying): return classify(underlying)
            default: return .other(apiError.localizedDescription)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .serverUnreachable
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .secureConnectionFailed:
                return .untrustedCertificate
            case .cannotWriteToFile, .cannotCreateFile:
                return .diskFull
            case .cancelled:
                return .cancelled
            default:
                return .other(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return .diskFull }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return .diskFull }
        return .other(error.localizedDescription)
    }
}

/// A failed download to tell the user about.
nonisolated struct DownloadFailureNotice: Identifiable, Sendable, Equatable {
    let id = UUID()
    let bookId: UUID
    let title: String
    let failure: DownloadFailure

    var message: String { failure.userMessage }
}

// MARK: - Planning

nonisolated enum RemoteDownloadPlanner {
    static let maxTrackBytes: Int64 = 2_000_000_000

    /// Builds the manifest for downloading every file of `item`, in play order.
    static func makeManifest(
        item: ABSLibraryItem,
        bookID: UUID,
        serverID: UUID?,
        title: String,
        attempt: UUID,
        now: Date
    ) throws -> RemoteDownloadManifest {
        let tracks = PlaybackTimeline.playbackOrder(item.media.tracks ?? [], startOffset: \.startOffset)
        guard !tracks.isEmpty else { throw DownloadFailure.invalidResponse }

        var offset = 0.0
        var manifestTracks: [RemoteDownloadManifest.Track] = []
        for (index, track) in tracks.enumerated() {
            guard let duration = track.duration, duration.isFinite, duration >= 0 else {
                throw DownloadFailure.invalidResponse
            }
            guard track.contentUrl != nil || track.ino != nil else { throw DownloadFailure.invalidResponse }
            let size = track.metadata?.size.flatMap { $0.isFinite && $0 >= 0 ? Int64($0) : nil }
            if let size, size > maxTrackBytes { throw DownloadFailure.fileTooLarge }
            let ext = fileExtension(for: track)
            manifestTracks.append(RemoteDownloadManifest.Track(
                index: index,
                fileName: RemoteDownloadManifest.trackFileName(index: index, ext: ext),
                startOffset: offset,
                duration: duration,
                size: size,
                ino: track.ino,
                ext: ext,
                mimeType: track.mimeType
            ))
            offset += duration
        }

        let chapters = RemoteChapterMapper.specs(from: item.media.chapters ?? [], timelineDuration: offset)
            .enumerated()
            .map { RemoteDownloadManifest.Chapter(id: $0.offset, start: $0.element.start, end: $0.element.end, title: $0.element.title) }

        return RemoteDownloadManifest(
            version: RemoteDownloadManifest.currentVersion,
            bookId: bookID,
            remoteItemId: item.id,
            serverId: serverID,
            attempt: attempt,
            title: title,
            tracks: manifestTracks,
            chapters: chapters,
            createdAt: now,
            completedAt: nil
        )
    }

    /// The file extension for a track: the server's file extension, then the
    /// original file name's, then one derived from the MIME type.
    static func fileExtension(for track: ABSAudioTrack) -> String {
        let candidates = [
            track.metadata?.ext.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 },
            track.metadata?.filename.map { ($0 as NSString).pathExtension },
            track.mimeType.flatMap(extensionForMimeType)
        ]
        for candidate in candidates {
            if let normalized = candidate?.lowercased(), isSafeExtension(normalized) {
                return normalized
            }
        }
        return "m4b"
    }

    static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 8 && value.range(of: #"^[a-z0-9+-]+$"#, options: .regularExpression) != nil
    }

    private static func extensionForMimeType(_ mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/x-m4b", "audio/m4b": return "m4b"
        case "audio/aac": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return nil
        }
    }
}

// MARK: - Staging

/// Partially downloaded books: `DownloadStaging/<bookUUID>/manifest.json` plus
/// the track files received so far. All moves into, out of and removals of
/// staging folders happen under one lock, because background download
/// callbacks arrive on a delegate queue while the main actor finalizes.
nonisolated enum DownloadStaging {
    enum StoreOutcome: Equatable, Sendable {
        case stored
        /// The staging folder is gone or belongs to another attempt.
        case discarded
        case sizeMismatch
        case failed(String)
    }

    private static let state = OSAllocatedUnfairLock<URL?>(initialState: nil)

    static var root: URL {
        state.withLock { $0 } ?? StorageManager.shared.downloadStagingDirectoryURL
    }

    /// Test seam: stage downloads somewhere else. Pass nil to restore.
    static func overrideRoot(_ url: URL?) {
        state.withLock { $0 = url }
    }

    static func folder(for bookID: UUID, root: URL = root) -> URL {
        root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func manifestURL(for bookID: UUID, root: URL = root) -> URL {
        folder(for: bookID, root: root).appendingPathComponent(RemoteDownloadManifest.fileName)
    }

    static func readManifest(for bookID: UUID, root: URL = root) throws -> RemoteDownloadManifest {
        try RemoteDownloadManifest.decode(Data(contentsOf: manifestURL(for: bookID, root: root)))
    }

    static func writeManifest(_ manifest: RemoteDownloadManifest, root: URL = root) throws {
        try state.withLock { _ in
            try manifest.encoded().write(to: manifestURL(for: manifest.bookId, root: root), options: .atomic)
        }
    }

    /// Creates (or reuses) the staging folder for a new attempt. Files already
    /// downloaded for the same server files are kept, so a retry fetches only
    /// the missing ones; anything else there is discarded.
    static func prepare(_ manifest: RemoteDownloadManifest, root: URL = root) throws {
        try state.withLock { _ in
            let fileManager = FileManager.default
            let folderURL = folder(for: manifest.bookId, root: root)
            if let existing = try? RemoteDownloadManifest.decode(Data(contentsOf: manifestURL(for: manifest.bookId, root: root))),
               !isCompatible(existing, with: manifest) {
                try? fileManager.removeItem(at: folderURL)
            }
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try manifest.encoded().write(to: manifestURL(for: manifest.bookId, root: root), options: .atomic)
        }
    }

    private static func isCompatible(_ existing: RemoteDownloadManifest, with new: RemoteDownloadManifest) -> Bool {
        existing.remoteItemId == new.remoteItemId
            && existing.tracks.map(\.fileName) == new.tracks.map(\.fileName)
            && existing.tracks.map(\.ino) == new.tracks.map(\.ino)
            && existing.tracks.map(\.size) == new.tracks.map(\.size)
    }

    /// Moves a finished download into its book's staging folder. Called on the
    /// URLSession delegate queue, synchronously, because `location` is deleted
    /// as soon as the delegate method returns.
    static func storeFinishedDownload(from location: URL, tag: DownloadTaskTag, root: URL = root) -> StoreOutcome {
        state.withLock { _ in
            let fileManager = FileManager.default
            guard let manifest = try? RemoteDownloadManifest.decode(Data(contentsOf: manifestURL(for: tag.bookId, root: root))),
                  manifest.attempt == tag.attempt,
                  manifest.tracks.indices.contains(tag.trackIndex) else {
                return .discarded
            }
            let track = manifest.tracks[tag.trackIndex]
            if let expectedIno = track.ino, let taggedIno = tag.ino, expectedIno != taggedIno {
                return .discarded
            }
            if let expected = track.size,
               let received = (try? fileManager.attributesOfItem(atPath: location.path))?[.size] as? NSNumber,
               received.int64Value != expected {
                return .sizeMismatch
            }
            let destination = folder(for: tag.bookId, root: root).appendingPathComponent(track.fileName)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: location, to: destination)
                try? fileManager.removeItem(at: resumeDataURL(for: tag.bookId, trackIndex: tag.trackIndex, root: root))
                return .stored
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Indices of tracks whose file is not yet in the staging folder with the
    /// expected size.
    static func missingTrackIndices(for manifest: RemoteDownloadManifest, root: URL = root) -> [Int] {
        let folderURL = folder(for: manifest.bookId, root: root)
        return manifest.tracks.enumerated().compactMap { index, track in
            let url = folderURL.appendingPathComponent(track.fileName)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return index }
            if let expected = track.size, (attributes[.size] as? NSNumber)?.int64Value != expected { return index }
            return nil
        }
    }

    static func receivedBytes(for manifest: RemoteDownloadManifest, root: URL = root) -> Int64 {
        let missing = Set(missingTrackIndices(for: manifest, root: root))
        return manifest.tracks.enumerated().reduce(0) { total, entry in
            missing.contains(entry.offset) ? total : total + (entry.element.size ?? 0)
        }
    }

    static func resumeDataURL(for bookID: UUID, trackIndex: Int, root: URL = root) -> URL {
        folder(for: bookID, root: root).appendingPathComponent(String(format: "%04d.resume", trackIndex + 1))
    }

    static func saveResumeData(_ data: Data, bookID: UUID, trackIndex: Int, root: URL = root) {
        state.withLock { _ in
            guard FileManager.default.fileExists(atPath: folder(for: bookID, root: root).path) else { return }
            try? data.write(to: resumeDataURL(for: bookID, trackIndex: trackIndex, root: root), options: .atomic)
        }
    }

    /// Returns and deletes the saved resume data for a track, if any.
    static func takeResumeData(bookID: UUID, trackIndex: Int, root: URL = root) -> Data? {
        state.withLock { _ in
            let url = resumeDataURL(for: bookID, trackIndex: trackIndex, root: root)
            guard let data = try? Data(contentsOf: url) else { return nil }
            try? FileManager.default.removeItem(at: url)
            return data
        }
    }

    /// Removes a book's staging folder; only direct children named by a UUID.
    static func removeFolder(for bookID: UUID, root: URL = root) {
        state.withLock { _ in
            try? FileManager.default.removeItem(at: folder(for: bookID, root: root))
        }
    }

    /// Runs `body` while no staging file can be moved in or out.
    static func withStagingLocked<T>(_ body: () throws -> T) rethrows -> T {
        try state.withLockUnchecked { _ in try body() }
    }

    /// Book IDs that currently have a staging folder.
    static func stagedBookIDs(root: URL = root) -> [UUID] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }
}
