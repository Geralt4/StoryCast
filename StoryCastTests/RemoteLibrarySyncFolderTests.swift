import XCTest
import SwiftData
@testable import StoryCast


private func makeRemoteItem(_ id: String, library: String = "library-1", title: String = "Title") -> ABSLibraryItem {
    ABSLibraryItem(
        id: id,
        libraryId: library,
        mediaType: "book",
        media: ABSBookMedia(
            metadata: ABSBookMetadata(
                title: title, subtitle: nil, authorName: "Author", narratorName: nil,
                description: nil, publishedYear: nil, publisher: nil, language: nil,
                isbn: nil, asin: nil, explicit: nil, abridged: nil
            ),
            coverPath: nil, duration: 120, numTracks: nil, numChapters: nil,
            audioFiles: nil, chapters: nil, tracks: nil
        ),
        addedAt: nil,
        updatedAt: nil
    )
}

nonisolated final class RemoteLibrarySyncFolderTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func item(_ id: String, library: String = "library-1", title: String = "Title") -> ABSLibraryItem {
        makeRemoteItem(id, library: library, title: title)
    }

    private func library(_ id: String, mediaType: String = "book") -> ABSLibrary {
        ABSLibrary(id: id, name: "Lib \(id)", mediaType: mediaType, displayOrder: 0, icon: nil, createdAt: nil, lastUpdate: nil)
    }

    @MainActor
    private func insertServer(in container: ModelContainer, isActive: Bool = true) throws -> ABSServer {
        let context = ModelContext(container)
        let server = ABSServer(name: "Home", url: "https://example.com", username: "tester", isActive: isActive)
        context.insert(server)
        try context.save()
        return server
    }

    // MARK: - mergeIntoStore

    @MainActor
    func testMergeAddsNewBooksToServerFolder() throws {
        let container = try makeContainer()
        let server = try insertServer(in: container)

        _ = try RemoteLibrarySyncEngine.mergeIntoStore(items: [item("a"), item("b")], server: server.snapshot(), container: container)

        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 2)
        XCTAssertTrue(books.allSatisfy { $0.folder?.id == server.id })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).filter { $0.id == server.id }.count, 1)
    }

    @MainActor
    func testMergeMovesExistingUnfiledRemoteBooksIntoServerFolder() throws {
        let container = try makeContainer()
        let server = try insertServer(in: container)
        let context = ModelContext(container)
        let unfiled = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(unfiled)
        context.insert(Book(title: "Old", duration: 10, folder: unfiled, isRemote: true, remoteItemId: "a", serverId: server.id))
        try context.save()

        _ = try RemoteLibrarySyncEngine.mergeIntoStore(items: [item("a")], server: server.snapshot(), container: container)

        let book = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Book>()).first)
        XCTAssertEqual(book.folder?.id, server.id)
    }

    @MainActor
    func testMergeKeepsBookTheUserMovedToAnotherFolder() throws {
        let container = try makeContainer()
        let server = try insertServer(in: container)
        let context = ModelContext(container)
        let mine = Folder(name: "Mine", isSystem: false, sortOrder: 1)
        context.insert(mine)
        context.insert(Book(title: "Old", duration: 10, folder: mine, isRemote: true, remoteItemId: "a", serverId: server.id))
        try context.save()
        let mineId = mine.id

        _ = try RemoteLibrarySyncEngine.mergeIntoStore(items: [item("a")], server: server.snapshot(), container: container)

        let book = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Book>()).first)
        XCTAssertEqual(book.folder?.id, mineId)
    }

    @MainActor
    func testMergeIsNoOpForInactiveServer() throws {
        let container = try makeContainer()
        let server = try insertServer(in: container, isActive: false)

        _ = try RemoteLibrarySyncEngine.mergeIntoStore(items: [item("a")], server: server.snapshot(), container: container)

        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Book>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Folder>()).isEmpty)
    }

    // MARK: - syncServer loop

    /// Records which library ids were requested; merges through the real `mergeIntoStore`.
    private final class PageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.withLock { ids.append(id) } }
        var requested: [String] { lock.withLock { ids } }
    }

    @MainActor
    private func runSync(
        server: ABSServer,
        container: ModelContainer,
        libraries: [ABSLibrary],
        log: PageLog
    ) async -> RemoteLibraryServerSyncResult {
        let makeItem: @Sendable (String, String) -> ABSLibraryItem = { id, libraryId in
            makeRemoteItem(id, library: libraryId)
        }
        return await RemoteLibrarySyncEngine.syncServer(
            for: server.snapshot(),
            container: container,
            validateServerAccess: { _, _ in true },
            fetchLibraries: { _ in libraries },
            fetchAndMergeLibraryPage: { snapshot, libraryId, page, container in
                log.record(libraryId)
                let items = page == 0 ? [makeItem("item-\(libraryId)", libraryId)] : []
                let requests = try await MainActor.run {
                    try RemoteLibrarySyncEngine.mergeIntoStore(items: items, server: snapshot, container: container)
                }
                let response = ABSLibraryItemsResponse(results: items, total: items.count, limit: 50, page: page)
                return RemoteLibraryPageSyncResult(response: response, coverArtRequests: requests)
            },
            enqueueCoverArtRequests: { _, _ in },
            persistLastSyncDate: { _, _ in }
        )
    }

    @MainActor
    func testSyncServerMergesEveryBookLibraryIntoOneFolderAndSkipsPodcasts() async throws {
        let container = try makeContainer()
        let server = try insertServer(in: container)
        let log = PageLog()

        let result = await runSync(
            server: server,
            container: container,
            libraries: [library("one"), library("pods", mediaType: "podcast"), library("two")],
            log: log
        )

        guard case .synced(let names) = result.outcome else { return XCTFail("Expected synced, got \(result.outcome)") }
        XCTAssertEqual(names, ["Lib one", "Lib two"])
        XCTAssertEqual(Set(log.requested), ["one", "two"])
        XCTAssertFalse(log.requested.contains("pods"))

        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(Set(books.compactMap(\.remoteLibraryId)), ["one", "two"])
        XCTAssertTrue(books.allSatisfy { $0.folder?.id == server.id })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).filter { $0.id == server.id }.count, 1)
    }

    @MainActor
    func testSyncServerWithOnlyPodcastLibrariesReportsNoLibraries() async throws {
        let container = try makeContainer()
        let server = try insertServer(in: container)
        let log = PageLog()

        let result = await runSync(server: server, container: container, libraries: [library("pods", mediaType: "podcast")], log: log)

        guard case .skippedNoLibraries = result.outcome else { return XCTFail("Expected skippedNoLibraries, got \(result.outcome)") }
        XCTAssertTrue(log.requested.isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Book>()).isEmpty)
    }
}
