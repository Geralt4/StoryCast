import XCTest
import AVFoundation
import SwiftData
@testable import StoryCast

nonisolated final class StartupStabilityTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
    }

    func testAppBootstrapUsesMigrationPlanWhenOpeningPersistentContainer() throws {
        var capturedMigrationPlanName: String?
        var capturedSchemaModels: [String] = []

        let state = AppBootstrap.makeStorageBootstrapState { schema, migrationPlan, _ in
            capturedMigrationPlanName = migrationPlan.map { String(describing: $0) }
            capturedSchemaModels = schema.entities.map(\.name)
            return AppBootstrap.makeRecoveryContainer()!
        }

        guard case .ready = state else {
            return XCTFail("Expected bootstrap to succeed with injected container factory")
        }

        XCTAssertEqual(capturedMigrationPlanName, String(describing: StoryCastMigrationPlan.self))
        XCTAssertTrue(capturedSchemaModels.contains("Book"))
        XCTAssertTrue(capturedSchemaModels.contains("ABSServer"))
    }

    @MainActor
    func testAppBootstrapReturnsRecoveryFailureWhenPersistentContainerCannotOpen() {
        let state = AppBootstrap.makeStorageBootstrapState { _, _, _ in
            throw NSError(domain: "BootstrapTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
        }

        guard case .failed(let failure) = state else {
            return XCTFail("Expected bootstrap to enter recovery mode")
        }

        XCTAssertTrue(failure.message.contains("couldn't open your library safely"))
        XCTAssertEqual(failure.technicalDetails, "simulated failure")
    }

    func testDeduplicationIgnoresRemoteBooksWithoutDeletingLibraryDirectory() async throws {
        let container = try makeInMemoryContainer()
        let libraryURL = try makeTemporaryDirectory()
        let localFileURL = try makeTemporaryAudioFile(in: libraryURL, named: "LocalBook.wav")
        let context = ModelContext(container)
        let folder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
        context.insert(folder)

        let localBook = Book(
            title: "Shared Title",
            author: "Same Author",
            localFileName: localFileURL.lastPathComponent,
            duration: 6,
            isImported: true,
            folder: folder
        )
        let remoteBook = Book(
            title: "Shared Title",
            author: "Same Author",
            duration: 6,
            isRemote: true,
            remoteItemId: "remote-1"
        )

        context.insert(localBook)
        context.insert(remoteBook)
        try context.save()

        let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container, libraryURL: libraryURL)
        let books = try context.fetch(FetchDescriptor<Book>())
        let didComplete = await MainActor.run { result.completed }
        let removedCount = await MainActor.run { result.removedCount }

        XCTAssertTrue(didComplete)
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(books.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localFileURL.path))
    }

    func testManagedLibraryAdoptionIsIdempotent() async throws {
        let container = try makeInMemoryContainer()
        let libraryURL = try makeTemporaryDirectory()
        let fileURL = try makeTemporaryAudioFile(in: libraryURL, named: "AdoptMe.wav")

        let firstResult = await LibraryMaintenanceService.adoptManagedLibraryFiles(container: container, libraryURL: libraryURL)
        let secondResult = await LibraryMaintenanceService.adoptManagedLibraryFiles(container: container, libraryURL: libraryURL)

        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<Book>())
        let firstAdoptedCount = await MainActor.run { firstResult.adoptedCount }
        let secondAdoptedCount = await MainActor.run { secondResult.adoptedCount }

        XCTAssertEqual(firstAdoptedCount, 1)
        XCTAssertEqual(secondAdoptedCount, 0)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.localFileName, fileURL.lastPathComponent)
    }

    @MainActor
    func testBackgroundRemoteSyncDoesNotMutateRemoteLibraryUIState() async throws {
        RemoteLibraryService.shared.debugResetUIState()
        await BackgroundRemoteCoverArtService.shared.debugResetState()

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Remote", url: "https://example.com", username: "tester")
        let serverId = server.id
        context.insert(server)
        try context.save()

        let tokenValid = await RemoteLibrarySyncEngine.syncPreferredLibrary(
            for: server.snapshot(),
            container: container,
            validateServerAccess: { _, container in
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                let persistedServer = try context.fetch(descriptor).first
                persistedServer?.defaultLibraryId = "library-1"
                try context.save()
                return true
            },
            fetchLibraries: { _ in
                [ABSLibrary(id: "library-1", name: "Main Library", mediaType: "book", displayOrder: 0, icon: nil, createdAt: nil, lastUpdate: nil)]
            },
            fetchAndMergeLibraryPage: { _, _, page, container in
                let response: ABSLibraryItemsResponse
                if page == 0 {
                    response = ABSLibraryItemsResponse(
                        results: [ABSLibraryItem(
                            id: "remote-item-1",
                            libraryId: "library-1",
                            mediaType: "book",
                            media: ABSBookMedia(
                                metadata: ABSBookMetadata(
                                    title: "Remote Title",
                                    subtitle: nil,
                                    authorName: "Remote Author",
                                    narratorName: nil,
                                    description: nil,
                                    publishedYear: nil,
                                    publisher: nil,
                                    language: nil,
                                    isbn: nil,
                                    asin: nil,
                                    explicit: nil,
                                    abridged: nil
                                ),
                                coverPath: nil,
                                duration: 120,
                                numTracks: nil,
                                numChapters: nil,
                                audioFiles: nil,
                                chapters: nil,
                                tracks: nil
                            ),
                            addedAt: nil,
                            updatedAt: nil
                        )],
                        total: 1,
                        limit: 50,
                        page: 0
                    )
                } else {
                    response = ABSLibraryItemsResponse(results: [], total: 1, limit: 50, page: page)
                }

                let context = ModelContext(container)
                if page == 0 {
                    let unfiledFolder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
                    context.insert(unfiledFolder)
                    let book = Book(
                        title: "Remote Title",
                        author: "Remote Author",
                        duration: 120,
                        folder: unfiledFolder,
                        isRemote: true,
                        remoteItemId: "remote-item-1",
                        remoteLibraryId: "library-1",
                        serverId: serverId,
                        lastSyncDate: Date()
                    )
                    context.insert(book)
                    try context.save()
                }

                return RemoteLibraryPageSyncResult(response: response, coverArtRequests: [])
            },
            enqueueCoverArtRequests: { _, _ in },
            persistLastSyncDate: { _, container in
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                let persistedServer = try context.fetch(descriptor).first
                persistedServer?.lastSyncDate = Date()
                try context.save()
            }
        )

        switch tokenValid.outcome {
        case .synced(let libraryId, let libraryName):
            XCTAssertEqual(libraryId, "library-1")
            XCTAssertEqual(libraryName, "Main Library")
        default:
            return XCTFail("Expected startup remote sync to succeed")
        }

        XCTAssertNil(RemoteLibraryService.shared.activeServer)
        XCTAssertTrue(RemoteLibraryService.shared.libraries.isEmpty)
        XCTAssertTrue(RemoteLibraryService.shared.remoteItems.isEmpty)
        XCTAssertNil(RemoteLibraryService.shared.error)
        XCTAssertTrue(RemoteLibraryService.shared.coverArtFailures.isEmpty)
        let backgroundTaskCountAfterMetadataSync = await BackgroundRemoteCoverArtService.shared.debugTaskCount()
        XCTAssertEqual(backgroundTaskCountAfterMetadataSync, 0)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.remoteItemId, "remote-item-1")
        XCTAssertNotNil(books.first?.lastSyncDate)

        var serverDescriptor = FetchDescriptor<ABSServer>()
        serverDescriptor.fetchLimit = 1
        let persistedServer = try context.fetch(serverDescriptor).first
        XCTAssertEqual(persistedServer?.defaultLibraryId, "library-1")
        XCTAssertNotNil(persistedServer?.lastSyncDate)
    }

    @MainActor
    func testBackgroundRemoteSyncQueuesBackgroundCoverArtWithoutMutatingUIFailures() async throws {
        RemoteLibraryService.shared.debugResetUIState()
        await BackgroundRemoteCoverArtService.shared.debugResetState()

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Remote", url: "https://example.com", username: "tester")
        let serverId = server.id
        let serverURL = server.normalizedURL
        let remoteBookId = UUID()
        context.insert(server)
        try context.save()

        let result = await RemoteLibrarySyncEngine.syncPreferredLibrary(
            for: server.snapshot(),
            container: container,
            validateServerAccess: { _, container in
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                let persistedServer = try context.fetch(descriptor).first
                persistedServer?.defaultLibraryId = "library-1"
                try context.save()
                return true
            },
            fetchLibraries: { _ in
                [ABSLibrary(id: "library-1", name: "Main Library", mediaType: "book", displayOrder: 0, icon: nil, createdAt: nil, lastUpdate: nil)]
            },
            fetchAndMergeLibraryPage: { _, _, page, container in
                let response = ABSLibraryItemsResponse(
                    results: page == 0 ? [ABSLibraryItem(
                        id: "remote-item-1",
                        libraryId: "library-1",
                        mediaType: "book",
                        media: ABSBookMedia(
                            metadata: ABSBookMetadata(
                                title: "Remote Title",
                                subtitle: nil,
                                authorName: "Remote Author",
                                narratorName: nil,
                                description: nil,
                                publishedYear: nil,
                                publisher: nil,
                                language: nil,
                                isbn: nil,
                                asin: nil,
                                explicit: nil,
                                abridged: nil
                            ),
                            coverPath: nil,
                            duration: 120,
                            numTracks: nil,
                            numChapters: nil,
                            audioFiles: nil,
                            chapters: nil,
                            tracks: nil
                        ),
                        addedAt: nil,
                        updatedAt: nil
                    )] : [],
                    total: 1,
                    limit: 50,
                    page: page
                )

                if page == 0 {
                    let context = ModelContext(container)
                    let unfiledFolder = Folder(name: "Unfiled", isSystem: true, sortOrder: 0)
                    context.insert(unfiledFolder)
                    context.insert(Book(
                        id: remoteBookId,
                        title: "Remote Title",
                        author: "Remote Author",
                        duration: 120,
                        folder: unfiledFolder,
                        isRemote: true,
                        remoteItemId: "remote-item-1",
                        remoteLibraryId: "library-1",
                        serverId: serverId,
                        lastSyncDate: Date()
                    ))
                    try context.save()
                }

                return RemoteLibraryPageSyncResult(
                    response: response,
                    coverArtRequests: page == 0 ? [
                        RemoteCoverArtRequest(bookId: remoteBookId, serverId: serverId, itemId: "remote-item-1", serverURL: serverURL)
                    ] : []
                )
            },
            enqueueCoverArtRequests: { requests, container in
                await BackgroundRemoteCoverArtService.shared.enqueue(requests: requests, container: container)
            },
            persistLastSyncDate: { _, _ in }
        )

        guard case .synced = result.outcome else {
            return XCTFail("Expected sync to succeed")
        }

        XCTAssertTrue(RemoteLibraryService.shared.coverArtFailures.isEmpty)
        let queuedBackgroundTaskCount = await BackgroundRemoteCoverArtService.shared.debugTaskCount()
        XCTAssertEqual(queuedBackgroundTaskCount, 1)

        await BackgroundRemoteCoverArtService.shared.debugResetState()
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        tempURLs.append(directoryURL)
        return directoryURL
    }

    private func makeTemporaryAudioFile(in directoryURL: URL, named fileName: String) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(fileName)
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        let frameCount = AVAudioFrameCount(sampleRate / 5)

        guard let format else {
            throw NSError(domain: "StartupStabilityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing audio format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "StartupStabilityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing audio buffer"])
        }

        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0, count: Int(frameCount))
        }

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try audioFile.write(from: buffer)
        return fileURL
    }
}
