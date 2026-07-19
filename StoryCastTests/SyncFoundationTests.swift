import CloudKit
import SwiftData
import XCTest
@testable import StoryCast

@MainActor
final class SyncFoundationTests: XCTestCase {
    func testRuntimeStoreCreatesOneDurableRuntime() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let first = try SyncRuntimeStore.runtime(in: context)
        let second = try SyncRuntimeStore.runtime(in: context)

        XCTAssertEqual(first.id, "runtime")
        XCTAssertTrue(first === second)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncRuntime>()).count, 1)
    }

    func testControllerDoesNotReportUpToDateWhileOutboxRemainsQueued() async throws {
        let container = try makeContainer()
        let transport = NoOpCloudSyncTransport()
        let controller = SyncController { _ in transport }
        try controller.setDesiredMode(.enabled, container: container)

        await controller.synchronizeIfEnabled(container: container, auditLibrary: false)

        guard case .waiting(let reason) = controller.status.activity else {
            return XCTFail("Expected a waiting status, got \(controller.status.activity)")
        }
        XCTAssertTrue(reason.contains("waiting to retry"))
        XCTAssertEqual(transport.prepareCount, 1)
        XCTAssertEqual(transport.sendCount, 1)
        XCTAssertEqual(transport.fetchCount, 1)
    }

    func testOutboxUpsertCoalescesPendingOperation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let first = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .book,
            subjectID: "book-1",
            payloadData: Data([1]),
            in: context
        )
        let second = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .book,
            subjectID: "book-1",
            payloadData: Data([2]),
            in: context
        )
        try context.save()

        XCTAssertEqual(first.id, second.id)
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?.payloadData, Data([2]))
    }

    func testOutboxWaitsForAcknowledgedDependencies() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let asset = try SyncOutboxStore.upsert(
            kind: .uploadAsset,
            subjectKind: .asset,
            subjectID: "asset-1",
            in: context
        )
        let book = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .book,
            subjectID: "book-1",
            dependencyIDs: [asset.id],
            in: context
        )
        try context.save()

        XCTAssertEqual(try SyncOutboxProcessor.readyOperations(in: context).map(\.id), [asset.id])

        SyncOutboxProcessor.markSent(asset)
        try context.save()

        XCTAssertEqual(try SyncOutboxProcessor.readyOperations(in: context).map(\.id), [book.id])
    }

    func testOutboxHonorsRetryDate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let operation = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-1",
            in: context
        )
        let retryDate = Date().addingTimeInterval(60)
        SyncOutboxProcessor.markRetry(operation, message: "Offline", retryAfter: retryDate)
        try context.save()

        XCTAssertTrue(try SyncOutboxProcessor.readyOperations(in: context, at: Date()).isEmpty)
        XCTAssertEqual(try SyncOutboxProcessor.readyOperations(in: context, at: retryDate).map(\.id), [operation.id])
    }

    func testOutboxUsesBackoffWhenCloudKitDoesNotProvideRetryDate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let operation = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-1",
            in: context
        )
        let markedAt = Date()

        SyncOutboxProcessor.markRetry(operation, message: "Transient failure", retryAfter: nil)

        XCTAssertGreaterThan(operation.nextRetryAt ?? .distantPast, markedAt)
        XCTAssertTrue(try SyncOutboxProcessor.readyOperations(in: context, at: markedAt).isEmpty)
        try SyncOutboxProcessor.resetRetries(in: context)
        XCTAssertNil(operation.nextRetryAt)
        XCTAssertEqual(try SyncOutboxProcessor.readyOperations(in: context).map(\.id), [operation.id])
    }

    func testImportedBookSnapshotExcludesAudiobookshelfFields() {
        let imported = Book(
            title: "Imported",
            author: "Author",
            localFileName: "book.m4b",
            duration: 120,
            lastPlaybackPosition: 42
        )
        let remote = Book(
            title: "Remote",
            localFileName: "cache.m4b",
            duration: 120,
            isRemote: true,
            remoteItemId: "remote-id",
            remoteLibraryId: "library",
            serverId: UUID(),
            isDownloaded: true,
            localCachePath: "cache.m4b"
        )

        let snapshot = SyncBookSnapshot(book: imported)
        XCTAssertEqual(snapshot?.bookID, imported.id)
        XCTAssertEqual(snapshot?.localFileName, "book.m4b")
        XCTAssertNil(SyncBookSnapshot(book: remote))
    }

    func testProgressResolverUsesTimestampThenSequenceThenActionID() {
        let bookID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let earlier = SyncProgressAction(
            bookID: bookID,
            deviceID: "device-a",
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            position: 90,
            actionAt: timestamp,
            sequence: 2,
            actionKind: "seek"
        )
        let later = SyncProgressAction(
            bookID: bookID,
            deviceID: "device-b",
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            position: 15,
            actionAt: timestamp.addingTimeInterval(1),
            sequence: 1,
            actionKind: "restart"
        )
        let sameTimeLaterSequence = SyncProgressAction(
            bookID: bookID,
            deviceID: "device-c",
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            position: 30,
            actionAt: timestamp,
            sequence: 3,
            actionKind: "pause"
        )

        XCTAssertEqual(SyncProgressConflictResolver.winner(earlier, later), later)
        XCTAssertEqual(SyncProgressConflictResolver.winner(earlier, sameTimeLaterSequence), sameTimeLaterSequence)
    }

    func testRecordNamesUseStableIDsInsteadOfUserContent() {
        let bookID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertEqual(SyncRecordName.book(bookID), "book/00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(SyncRecordName.asset(assetID, revision: 3), "asset/00000000-0000-0000-0000-000000000002/3")
        XCTAssertFalse(SyncRecordName.book(bookID).contains("Imported"))
    }

    func testAuditCreatesSidecarsOnlyForImportedBooks() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncAudit_\(UUID().uuidString)")
        let libraryDirectory = tempDirectory.appendingPathComponent("Library")
        let coverArtDirectory = tempDirectory.appendingPathComponent("CoverArt")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coverArtDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let audioName = "book.m4b"
        let coverName = "cover.jpg"
        try Data([1, 2, 3, 4]).write(to: libraryDirectory.appendingPathComponent(audioName))
        try Data([5, 6]).write(to: coverArtDirectory.appendingPathComponent(coverName))

        let folder = Folder(name: "Imported", isSystem: false, sortOrder: 0)
        let imported = Book(
            title: "Imported",
            localFileName: audioName,
            duration: 120,
            folder: folder,
            coverArtFileName: coverName
        )
        let remote = Book(
            title: "Remote",
            localFileName: "remote.m4b",
            duration: 120,
            folder: folder,
            isRemote: true,
            remoteItemId: "remote-id",
            serverId: UUID()
        )
        context.insert(folder)
        context.insert(imported)
        context.insert(remote)
        try context.save()

        let result = await SyncLibraryAuditor.audit(
            container: container,
            deviceID: "device-a",
            libraryURL: libraryDirectory,
            coverArtDirectoryURL: coverArtDirectory
        )

        XCTAssertEqual(result.importedBookCount, 1)
        XCTAssertEqual(result.verifiedAssetCount, 2)
        XCTAssertEqual(result.missingAssetCount, 0)
        let assets = try context.fetch(FetchDescriptor<SyncAsset>())
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets.allSatisfy { $0.bookID == imported.id })
        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        XCTAssertTrue(states.contains { $0.id == "book:\(imported.id.uuidString.lowercased())" })
        XCTAssertFalse(states.contains { $0.id == "book:\(remote.id.uuidString.lowercased())" })
    }

    func testPlannerCreatesDependencyOrderedFullLibraryOutbox() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let folder = Folder(name: "Fiction", isSystem: false, sortOrder: 1)
        let book = Book(
            title: "Imported",
            author: "Author",
            localFileName: "book.m4b",
            duration: 120,
            folder: folder,
            coverArtFileName: "cover.jpg"
        )
        let chapter = Chapter(title: "One", startTime: 0, endTime: 60, source: .embedded, book: book)
        let audio = SyncAsset(
            bookID: book.id,
            kindRaw: SyncAssetKind.audio.rawValue,
            originalFileName: "book.m4b",
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 4,
            sha256Hex: "audio-digest",
            localRelativePath: "book.m4b",
            localStateRaw: SyncAssetLocalState.verified.rawValue,
            lastVerifiedAt: Date()
        )
        let cover = SyncAsset(
            bookID: book.id,
            kindRaw: SyncAssetKind.coverArt.rawValue,
            originalFileName: "cover.jpg",
            pathExtension: "jpg",
            contentTypeIdentifier: "public.image",
            byteCount: 2,
            sha256Hex: "cover-digest",
            localRelativePath: "cover.jpg",
            localStateRaw: SyncAssetLocalState.verified.rawValue,
            lastVerifiedAt: Date()
        )
        context.insert(folder)
        context.insert(book)
        context.insert(chapter)
        context.insert(audio)
        context.insert(cover)
        try context.save()

        let result = try SyncOutboxPlanner.plan(container: container, deviceID: "device-a")
        XCTAssertEqual(result.bookCount, 1)

        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        let generation = try XCTUnwrap(operations.first { $0.subjectKindRaw == SyncEntityKind.generation.rawValue })
        let folderOperation = try XCTUnwrap(operations.first { $0.subjectKindRaw == SyncEntityKind.folder.rawValue })
        let audioOperation = try XCTUnwrap(operations.first { $0.subjectID == SyncRecordName.asset(audio.id, revision: 1) })
        let coverOperation = try XCTUnwrap(operations.first { $0.subjectID == SyncRecordName.asset(cover.id, revision: 1) })
        let bookOperation = try XCTUnwrap(operations.first { $0.subjectKindRaw == SyncEntityKind.book.rawValue })
        let chapterOperation = try XCTUnwrap(operations.first { $0.subjectKindRaw == SyncEntityKind.chapter.rawValue })
        let progressOperation = try XCTUnwrap(operations.first { $0.subjectKindRaw == SyncEntityKind.progress.rawValue })

        XCTAssertEqual(try SyncOutboxProcessor.readyOperations(in: context).map(\.id), [generation.id])
        XCTAssertEqual(Set(try SyncOutboxDependencyCodec.decode(folderOperation.dependencyData)), [generation.id])
        XCTAssertEqual(Set(try SyncOutboxDependencyCodec.decode(audioOperation.dependencyData)), [generation.id])
        XCTAssertEqual(Set(try SyncOutboxDependencyCodec.decode(coverOperation.dependencyData)), [generation.id])
        XCTAssertEqual(
            Set(try SyncOutboxDependencyCodec.decode(bookOperation.dependencyData)),
            [generation.id, folderOperation.id, audioOperation.id, coverOperation.id]
        )
        XCTAssertEqual(Set(try SyncOutboxDependencyCodec.decode(chapterOperation.dependencyData)), [bookOperation.id])
        XCTAssertEqual(Set(try SyncOutboxDependencyCodec.decode(progressOperation.dependencyData)), [bookOperation.id])

        let secondPlan = try SyncOutboxPlanner.plan(container: container, deviceID: "device-a")
        XCTAssertEqual(secondPlan.operationCount, 0)
    }

    func testPlannerQueuesNewRevisionsForMetadataAndChapterChanges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let folder = Folder(name: "Fiction", isSystem: false, sortOrder: 1)
        let book = Book(title: "Original", localFileName: "book.m4b", duration: 120, folder: folder)
        let chapter = Chapter(title: "Chapter", startTime: 0, endTime: 120, source: .embedded, book: book)
        let audio = SyncAsset(
            bookID: book.id,
            kindRaw: SyncAssetKind.audio.rawValue,
            originalFileName: "book.m4b",
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 4,
            sha256Hex: "digest",
            localRelativePath: "book.m4b",
            localStateRaw: SyncAssetLocalState.verified.rawValue,
            lastVerifiedAt: Date()
        )
        context.insert(folder)
        context.insert(book)
        context.insert(chapter)
        context.insert(audio)
        try context.save()

        _ = try SyncOutboxPlanner.plan(container: container, deviceID: "device-a")
        for operation in try context.fetch(FetchDescriptor<SyncOutboxOperation>()) {
            SyncOutboxProcessor.markSent(operation)
        }
        audio.cloudStateRaw = SyncAssetCloudState.published.rawValue
        try context.save()

        book.title = "Renamed"
        try context.save()
        let bookUpdate = try SyncOutboxPlanner.plan(container: container, deviceID: "device-a")
        XCTAssertEqual(bookUpdate.operationCount, 1)
        let pendingBook = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxOperation>()).first {
                $0.subjectKindRaw == SyncEntityKind.book.rawValue && $0.stateRaw == "queued"
            }
        )
        let bookPayload = try CloudSyncRecordCodec.decodePayload(
            CloudSyncBookPayload.self,
            from: try XCTUnwrap(pendingBook.payloadData)
        )
        XCTAssertEqual(bookPayload.title, "Renamed")
        XCTAssertEqual(bookPayload.revision, 2)
        SyncOutboxProcessor.markSent(pendingBook)
        try context.save()

        chapter.title = "Updated Chapter"
        try context.save()
        let chapterUpdate = try SyncOutboxPlanner.plan(container: container, deviceID: "device-a")
        XCTAssertEqual(chapterUpdate.operationCount, 1)
        let pendingChapter = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxOperation>()).first {
                $0.subjectKindRaw == SyncEntityKind.chapter.rawValue && $0.stateRaw == "queued"
            }
        )
        let chapterPayload = try CloudSyncRecordCodec.decodePayload(
            CloudSyncChapterPayload.self,
            from: try XCTUnwrap(pendingChapter.payloadData)
        )
        XCTAssertEqual(chapterPayload.title, "Updated Chapter")
        XCTAssertEqual(chapterPayload.revision, 2)
    }

    func testInboxAppliesBookWithoutAudiobookshelfState() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let folderID = UUID()
        let bookID = UUID()
        let audioID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        context.insert(SyncAsset(
            id: audioID,
            bookID: bookID,
            kindRaw: SyncAssetKind.audio.rawValue,
            originalFileName: "book.m4b",
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 4,
            sha256Hex: "digest",
            localRelativePath: "icloud-audio.m4b",
            localStateRaw: SyncAssetLocalState.verified.rawValue,
            cloudStateRaw: SyncAssetCloudState.published.rawValue
        ))
        try context.save()

        let folderPayload = CloudSyncFolderPayload(
            folderID: folderID,
            name: "Synced",
            isSystem: false,
            sortOrder: 2,
            revision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            deviceID: "device-a"
        )
        let folderRecord = try CloudSyncRecordCodec.makeRecord(
            type: .folder,
            recordName: SyncRecordName.folder(folderID),
            zoneID: zoneID,
            payload: folderPayload
        )
        try await SyncInboxApplier.stage(record: folderRecord, container: container)

        let bookPayload = CloudSyncBookPayload(
            bookID: bookID,
            title: "Cloud Book",
            author: "Author",
            duration: 120,
            folderID: folderID,
            audioAssetID: audioID,
            coverArtAssetID: nil,
            chapterSetID: bookID,
            revision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            deviceID: "device-a"
        )
        let bookRecord = try CloudSyncRecordCodec.makeRecord(
            type: .book,
            recordName: SyncRecordName.book(bookID),
            zoneID: zoneID,
            payload: bookPayload
        )
        try await SyncInboxApplier.stage(record: bookRecord, container: container)

        let verificationContext = ModelContext(container)
        let syncedBook = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Book>()).first(where: { $0.id == bookID })
        )
        XCTAssertEqual(syncedBook.localFileName, "icloud-audio.m4b")
        XCTAssertEqual(syncedBook.folder?.id, folderID)
        XCTAssertFalse(syncedBook.isRemote)
        XCTAssertNil(syncedBook.remoteItemId)
        XCTAssertNil(syncedBook.remoteLibraryId)
        XCTAssertNil(syncedBook.serverId)
        XCTAssertNil(syncedBook.localCachePath)
    }

    func testInboxWaitsForOutOfOrderChapters() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let book = Book(title: "Book", localFileName: "book.m4b", duration: 180)
        context.insert(book)
        try context.save()
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")

        func record(index: Int) throws -> CKRecord {
            let payload = CloudSyncChapterPayload(
                bookID: book.id,
                chapterSetID: book.id,
                index: index,
                title: "Chapter \(index)",
                startTime: Double(index * 60),
                endTime: Double((index + 1) * 60),
                sourceRaw: ChapterSource.embedded.rawValue,
                revision: 1,
                modifiedAt: Date(timeIntervalSince1970: 1_000),
                deviceID: "device-a"
            )
            return try CloudSyncRecordCodec.makeRecord(
                type: .chapter,
                recordName: SyncRecordName.chapter(bookID: book.id, chapterSetID: book.id, index: index),
                zoneID: zoneID,
                payload: payload
            )
        }

        try await SyncInboxApplier.stage(record: try record(index: 2), container: container)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Chapter>()).isEmpty)

        try await SyncInboxApplier.stage(record: try record(index: 0), container: container)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Chapter>()).count, 1)

        try await SyncInboxApplier.stage(record: try record(index: 1), container: container)
        let chapters = try ModelContext(container).fetch(FetchDescriptor<Chapter>()).sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(chapters.map(\.title), ["Chapter 0", "Chapter 1", "Chapter 2"])
        let inbox = try ModelContext(container).fetch(FetchDescriptor<SyncInboxRecord>())
        XCTAssertTrue(inbox.allSatisfy { $0.stateRaw == "applied" })
    }

    func testTombstonePreventsLateBookRecordFromRecreatingBook() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let book = Book(title: "Deleted", localFileName: "missing.m4b", duration: 120)
        let bookID = book.id
        context.insert(book)
        try context.save()
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        let tombstonePayload = CloudSyncTombstonePayload(
            entityKind: .book,
            entityID: bookID.uuidString.lowercased(),
            deletedAt: Date(timeIntervalSince1970: 2_000),
            revision: 1,
            deviceID: "device-a"
        )
        let tombstoneRecord = try CloudSyncRecordCodec.makeRecord(
            type: .tombstone,
            recordName: SyncRecordName.tombstone(kind: .book, id: bookID.uuidString.lowercased()),
            zoneID: zoneID,
            payload: tombstonePayload
        )
        try await SyncInboxApplier.stage(record: tombstoneRecord, container: container)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Book>()).isEmpty)

        let lateBookPayload = CloudSyncBookPayload(
            bookID: bookID,
            title: "Late Record",
            author: nil,
            duration: 120,
            folderID: nil,
            audioAssetID: UUID(),
            coverArtAssetID: nil,
            chapterSetID: bookID,
            revision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            deviceID: "device-b"
        )
        let lateBookRecord = try CloudSyncRecordCodec.makeRecord(
            type: .book,
            recordName: SyncRecordName.book(bookID),
            zoneID: zoneID,
            payload: lateBookPayload
        )
        try await SyncInboxApplier.stage(record: lateBookRecord, container: container)

        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Book>()).isEmpty)
        let bookInbox = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<SyncInboxRecord>()).first {
                $0.id == SyncRecordName.book(bookID)
            }
        )
        XCTAssertEqual(bookInbox.stateRaw, "applied")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}

@MainActor
private final class NoOpCloudSyncTransport: CloudSyncTransport {
    private(set) var prepareCount = 0
    private(set) var sendCount = 0
    private(set) var fetchCount = 0

    func prepareZoneAndFetchChanges() async throws { prepareCount += 1 }
    func sendPendingChanges() async throws { sendCount += 1 }
    func fetchChanges() async throws { fetchCount += 1 }
    func cancel() async {}
}
