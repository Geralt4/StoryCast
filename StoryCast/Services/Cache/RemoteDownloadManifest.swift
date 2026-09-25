import Foundation

/// Describes a downloaded Audiobookshelf book stored as a folder:
/// `RemoteAudioCache/<bookUUID>_remote/manifest.json` plus `0001.<ext>` … one
/// file per server track, in play order.
nonisolated struct RemoteDownloadManifest: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let fileName = "manifest.json"
    static let maximumSize = 1_000_000

    nonisolated struct Track: Codable, Sendable, Equatable {
        /// Position in play order, starting at 0.
        var index: Int
        var fileName: String
        var startOffset: Double
        var duration: Double
        /// Expected size in bytes, when the server reported one.
        var size: Int64?
        var ino: String?
        var ext: String
        var mimeType: String?
    }

    nonisolated struct Chapter: Codable, Sendable, Equatable {
        var id: Int
        var start: Double
        var end: Double
        var title: String
    }

    var version: Int
    var bookId: UUID
    var remoteItemId: String
    var serverId: UUID?
    /// Identifies one download attempt; files from an earlier attempt are
    /// never accepted into a newer one.
    var attempt: UUID
    var title: String
    var tracks: [Track]
    var chapters: [Chapter]
    var createdAt: Date
    /// Set once every track file is in place.
    var completedAt: Date?

    static func trackFileName(index: Int, ext: String) -> String {
        String(format: "%04d.%@", index + 1, ext)
    }

    var absChapters: [ABSChapter] {
        chapters.map { ABSChapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title) }
    }

    var timeline: PlaybackTimeline? {
        PlaybackTimeline(durations: tracks.map(\.duration))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RemoteDownloadManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RemoteDownloadManifest.self, from: data)
    }

    /// The playable source for a validated download folder.
    func playbackSource(folderURL: URL) -> PlaybackSource? {
        guard let timeline else { return nil }
        let urls = tracks.map { folderURL.appendingPathComponent($0.fileName, isDirectory: false) }
        return PlaybackSource(bookID: bookId, identityURL: folderURL, trackURLs: urls, timeline: timeline)
    }
}

/// How a remote book's `localCachePath` maps onto the disk.
nonisolated enum RemoteDownloadLayout {
    static let folderSuffix = "_remote"

    enum Resolution: Equatable, Sendable {
        /// A pre-1.4 download: one audio file named `<uuid>_remote.<ext>`.
        case legacyFile(URL)
        case folder(URL, RemoteDownloadManifest)
        case missing
        /// The download is structurally broken (bad manifest, missing or foreign
        /// files) and should be discarded.
        case invalid(String)
        /// The files couldn't be read right now (for example protected data is
        /// unavailable); the download itself may be fine.
        case unreadable(String)
    }

    static func folderName(for bookID: UUID) -> String {
        bookID.uuidString + folderSuffix
    }

    static func isDownloadFolderName(_ name: String) -> Bool {
        guard name.hasSuffix(folderSuffix) else { return false }
        return UUID(uuidString: String(name.dropLast(folderSuffix.count))) != nil
    }

    static func isTrackFileName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{4,}\.[a-z0-9+-]{1,8}$"#, options: .regularExpression) != nil
    }

    static func folderURL(named name: String, cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Cheap check (at most two file-system lookups) used to decide whether a
    /// downloaded book should play locally. Full validation happens in `resolve`.
    static func quickIdentityURL(localCachePath: String, cacheRoot: URL) -> URL? {
        guard StorageCleanupCoordinator.isSafeRelativePath(localCachePath) else { return nil }
        let fileManager = FileManager.default
        if isDownloadFolderName(localCachePath) {
            let folderURL = folderURL(named: localCachePath, cacheRoot: cacheRoot)
            let manifestURL = folderURL.appendingPathComponent(RemoteDownloadManifest.fileName)
            return fileManager.fileExists(atPath: manifestURL.path) ? folderURL : nil
        }
        let fileURL = cacheRoot.appendingPathComponent(localCachePath)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    static func resolve(localCachePath: String, cacheRoot: URL, expectedBookID: UUID) -> Resolution {
        guard StorageCleanupCoordinator.isSafeRelativePath(localCachePath) else {
            return .invalid("unsafe cache path")
        }
        if isDownloadFolderName(localCachePath) {
            guard localCachePath == folderName(for: expectedBookID) else {
                return .invalid("download folder belongs to another book")
            }
            return resolveFolder(folderURL(named: localCachePath, cacheRoot: cacheRoot), expectedBookID: expectedBookID)
        }
        let fileURL = cacheRoot.appendingPathComponent(localCachePath)
        switch itemType(at: fileURL) {
        case .success(.typeRegular): return .legacyFile(fileURL)
        case .success(nil): return .missing
        case .success: return .invalid("cached audio is not a regular file")
        case .failure(let error): return .unreadable(error.localizedDescription)
        }
    }

    private static func resolveFolder(_ folderURL: URL, expectedBookID: UUID) -> Resolution {
        switch itemType(at: folderURL) {
        case .success(.typeDirectory): break
        case .success(nil): return .missing
        case .success: return .invalid("download is not a folder")
        case .failure(let error): return .unreadable(error.localizedDescription)
        }

        let manifestURL = folderURL.appendingPathComponent(RemoteDownloadManifest.fileName)
        let manifest: RemoteDownloadManifest
        switch itemAttributes(at: manifestURL) {
        case .success(nil):
            return .invalid("manifest is missing")
        case .success(let attributes?):
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .invalid("manifest is not a regular file")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= RemoteDownloadManifest.maximumSize else { return .invalid("manifest is too large") }
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                return .unreadable(error.localizedDescription)
            }
            do {
                manifest = try RemoteDownloadManifest.decode(data)
            } catch {
                return .invalid("manifest can't be decoded")
            }
        case .failure(let error):
            return .unreadable(error.localizedDescription)
        }

        guard manifest.version == RemoteDownloadManifest.currentVersion else { return .invalid("unsupported manifest version") }
        guard manifest.bookId == expectedBookID else { return .invalid("manifest belongs to another book") }
        guard manifest.completedAt != nil else { return .invalid("download is incomplete") }
        guard !manifest.tracks.isEmpty, manifest.timeline != nil else { return .invalid("manifest has no playable tracks") }
        guard Set(manifest.tracks.map(\.fileName)).count == manifest.tracks.count else {
            return .invalid("manifest lists a file twice")
        }

        for track in manifest.tracks {
            guard isTrackFileName(track.fileName) else { return .invalid("unexpected track file name") }
            let trackURL = folderURL.appendingPathComponent(track.fileName, isDirectory: false)
            guard trackURL.deletingLastPathComponent().standardizedFileURL.path == folderURL.standardizedFileURL.path else {
                return .invalid("track file is outside the download folder")
            }
            switch itemAttributes(at: trackURL) {
            case .success(nil):
                return .invalid("track file \(track.fileName) is missing")
            case .success(let attributes?):
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    return .invalid("track file \(track.fileName) is not a regular file")
                }
                if let expected = track.size, let actual = (attributes[.size] as? NSNumber)?.int64Value, expected != actual {
                    return .invalid("track file \(track.fileName) has the wrong size")
                }
            case .failure(let error):
                return .unreadable(error.localizedDescription)
            }
        }
        return .folder(folderURL, manifest)
    }

    /// Attributes without following symlinks, or nil when nothing exists there.
    private static func itemAttributes(at url: URL) -> Result<[FileAttributeKey: Any]?, Error> {
        do {
            return .success(try FileManager.default.attributesOfItem(atPath: url.path))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    private static func itemType(at url: URL) -> Result<FileAttributeType?, Error> {
        itemAttributes(at: url).map { $0?[.type] as? FileAttributeType }
    }

    // MARK: - Trash

    /// Where download folders go before they are deleted in the background.
    static var trashDirectoryURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupportURL.appendingPathComponent("StoryCast/DownloadTrash", isDirectory: true)
    }

    /// Moves a download folder out of the cache in O(1), so removing a large
    /// book doesn't block the caller, then deletes it in the background.
    static func trashFolder(at folderURL: URL, trashRoot: URL = trashDirectoryURL) throws {
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        let destination = trashRoot.appendingPathComponent("\(folderURL.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: folderURL, to: destination)
        emptyTrash(trashRoot: trashRoot)
    }

    /// Deletes everything in the trash in the background; also run at launch.
    static func emptyTrash(trashRoot: URL = trashDirectoryURL) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let entries = try? fileManager.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) else { return }
            for entry in entries {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
