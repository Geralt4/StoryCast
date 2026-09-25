import Foundation
import SwiftData
import XCTest
@testable import StoryCast

nonisolated final class LegacyRemoteDownloadValidatorTests: XCTestCase {
    private let serverURL = "https://abs-legacy-validator-test.example.com"
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        ABSStubURLProtocol.reset()
        try await AudiobookshelfAuth.shared.saveToken("legacy-token", for: serverURL)
        try await StorageManager.shared.setupRemoteAudioCacheDirectory()
    }

    override func tearDown() async throws {
        try? await AudiobookshelfAuth.shared.deleteToken(for: serverURL)
        ABSStubURLProtocol.reset()
        for url in createdFiles { try? FileManager.default.removeItem(at: url) }
        createdFiles.removeAll()
        await MainActor.run { AudioPlayerService.shared.unload() }
    }

    // MARK: - Pure rules

    func testVerdictRules() {
        XCTAssertEqual(LegacyRemoteDownloadValidator.verdict(serverTrackCount: nil, fileKind: .mp4, fileExtension: "m4b"), .undetermined)
        XCTAssertEqual(LegacyRemoteDownloadValidator.verdict(serverTrackCount: 3, fileKind: .mp3, fileExtension: "m4b"), .truncated)
        XCTAssertEqual(LegacyRemoteDownloadValidator.verdict(serverTrackCount: 1, fileKind: .mp4, fileExtension: "m4b"), .valid)
        XCTAssertEqual(LegacyRemoteDownloadValidator.verdict(serverTrackCount: 1, fileKind: .mp3, fileExtension: "m4b"), .wrongExtension("mp3"))
        XCTAssertEqual(LegacyRemoteDownloadValidator.verdict(serverTrackCount: 1, fileKind: nil, fileExtension: "m4b"), .valid)
    }

    func testFileKindSniffing() {
        XCTAssertEqual(AudioFileKind.sniff(Data("ID3\u{3}\0\0\0\0".utf8)), .mp3)
        XCTAssertEqual(AudioFileKind.sniff(Data([0xFF, 0xFB, 0x90, 0x00])), .mp3)
        XCTAssertEqual(AudioFileKind.sniff(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)), .mp4)
        XCTAssertEqual(AudioFileKind.sniff(Data("fLaC".utf8)), .flac)
        XCTAssertEqual(AudioFileKind.sniff(Data("OggS".utf8)), .ogg)
        XCTAssertNil(AudioFileKind.sniff(Data("hello world!".utf8)))
    }

    // MARK: - Applying

    @MainActor
    func testTruncatedDownloadIsRemovedWhenServerConfirmsSeveralFiles() async throws {
        let (container, book, fileURL) = try makeLegacyDownload(fixture: "abs-item-mp3-multi", header: Data("ID3\u{3}".utf8))

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: ABSStubURLProtocol.makeAPI())

        let saved = try fetch(book.id, container)
        XCTAssertFalse(saved.isDownloaded)
        XCTAssertNil(saved.localCachePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testCompleteSingleFileDownloadIsVerifiedAndNotCheckedAgain() async throws {
        let (container, book, fileURL) = try makeLegacyDownload(fixture: "abs-item-m4b-single", header: Data([0, 0, 0, 0x20]) + Data("ftypM4B ".utf8))
        let api = ABSStubURLProtocol.makeAPI()

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: api)
        let requestsAfterFirstRun = ABSStubURLProtocol.requests.count
        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: api)

        let saved = try fetch(book.id, container)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(LegacyRemoteDownloadValidator.isVerified(bookID: book.id, cachePath: try XCTUnwrap(saved.localCachePath)))
        XCTAssertEqual(ABSStubURLProtocol.requests.count, requestsAfterFirstRun)
    }

    @MainActor
    func testMP3SavedAsM4BIsRenamed() async throws {
        let (container, book, fileURL) = try makeLegacyDownload(fixture: "abs-item-m4b-single", header: Data("ID3\u{3}".utf8))

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: ABSStubURLProtocol.makeAPI())

        let saved = try fetch(book.id, container)
        let renamed = "\(book.id.uuidString)_remote.mp3"
        createdFiles.append(StorageManager.shared.remoteAudioCacheURL(for: renamed))
        XCTAssertEqual(saved.localCachePath, renamed)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: StorageManager.shared.remoteAudioCacheURL(for: renamed).path))
    }

    @MainActor
    func testOfflineNeverRemovesADownload() async throws {
        let (container, book, fileURL) = try makeLegacyDownload(fixture: nil, header: Data("ID3\u{3}".utf8))

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: ABSStubURLProtocol.makeAPI())

        let saved = try fetch(book.id, container)
        XCTAssertTrue(saved.isDownloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(LegacyRemoteDownloadValidator.isVerified(bookID: book.id, cachePath: try XCTUnwrap(saved.localCachePath)))
    }

    @MainActor
    func testBookLoadedInPlayerIsLeftAlone() async throws {
        let (container, book, fileURL) = try makeLegacyDownload(fixture: "abs-item-mp3-multi", header: Data("ID3\u{3}".utf8))
        AudioPlayerService.shared.load(source: .singleFile(url: fileURL, duration: 10, bookID: book.id), title: "Playing", seekTo: 0)

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: ABSStubURLProtocol.makeAPI())

        XCTAssertTrue(try fetch(book.id, container).isDownloaded)
    }

    @MainActor
    func testFolderDownloadsAreSkipped() async throws {
        let container = try makeContainer()
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let book = Book(title: "Folder", duration: 10, isRemote: true, remoteItemId: "item", serverId: server.id, isDownloaded: true, localCachePath: "\(UUID().uuidString)_remote")
        container.mainContext.insert(server)
        container.mainContext.insert(book)
        try container.mainContext.save()

        await LegacyRemoteDownloadValidator.runIfNeeded(container: container, api: ABSStubURLProtocol.makeAPI())

        XCTAssertTrue(ABSStubURLProtocol.requests.isEmpty)
    }

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    /// A book with an older single-file download; `fixture` is the server's
    /// item response (nil means the server can't be reached).
    @MainActor
    private func makeLegacyDownload(fixture: String?, header: Data) throws -> (ModelContainer, Book, URL) {
        let container = try makeContainer()
        let server = ABSServer(name: "Test", url: serverURL, username: "root")
        let itemID: String
        if let fixture {
            let item = try ABSFixtures.libraryItem(fixture)
            itemID = item.id
            ABSStubURLProtocol.stub(path: "/api/items/\(item.id)", body: try ABSFixtures.data(fixture))
        } else {
            itemID = "offline-item"
        }
        let book = Book(title: "Legacy", duration: 283, isRemote: true, remoteItemId: itemID, serverId: server.id, isDownloaded: true)
        let fileName = "\(book.id.uuidString)_remote.m4b"
        book.localCachePath = fileName
        let fileURL = StorageManager.shared.remoteAudioCacheURL(for: fileName)
        try (header + Data(repeating: 0, count: 64)).write(to: fileURL)
        createdFiles.append(fileURL)
        container.mainContext.insert(server)
        container.mainContext.insert(book)
        try container.mainContext.save()
        return (container, book, fileURL)
    }

    @MainActor
    private func fetch(_ id: UUID, _ container: ModelContainer) throws -> Book {
        try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })).first)
    }
}
