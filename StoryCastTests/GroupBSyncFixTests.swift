import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import StoryCast

/// Regression tests for the Group B CloudKit sync hardening fixes.
@MainActor
final class GroupBSyncFixTests: XCTestCase {

    // MARK: - M6 — readyOperations must skip corrupt dependency data

    func testReadyOperationsSkipsCorruptDependencyData() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let good = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-good",
            in: context
        )
        let corrupt = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .folder,
            subjectID: "folder-corrupt",
            in: context
        )
        // Inject undecodable dependency bytes. readyOperations must not throw;
        // the corrupt row is simply not ready.
        corrupt.dependencyData = Data([0xFF, 0x00, 0xDE, 0xAD])
        try context.save()

        let ready = try SyncOutboxProcessor.readyOperations(in: context)
        XCTAssertEqual(ready.map(\.id), [good.id])
        XCTAssertFalse(ready.contains(where: { $0.id == corrupt.id }))
    }

    // MARK: - M7 — chapter apply matches by (startTime, title) before index

    func testInboxChapterMatchesByTitleAndStartTimeOverIndex() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let book = Book(title: "Book", localFileName: "book.m4b", duration: 180)
        let chapterA = Chapter(title: "Alpha", startTime: 0, endTime: 60, source: .embedded, book: book)
        let chapterB = Chapter(title: "Beta", startTime: 60, endTime: 120, source: .embedded, book: book)
        context.insert(book)
        context.insert(chapterA)
        context.insert(chapterB)
        try context.save()

        // Incoming payload claims index 0, but its identity is Beta@60.
        // Index matching would overwrite Alpha; identity matching updates Beta.
        let payload = CloudSyncChapterPayload(
            bookID: book.id,
            chapterSetID: book.id,
            index: 0,
            title: "Beta",
            startTime: 60,
            endTime: 150,
            sourceRaw: ChapterSource.embedded.rawValue,
            revision: 2,
            modifiedAt: Date(timeIntervalSince1970: 2_000),
            deviceID: "device-b"
        )
        let record = try CloudSyncRecordCodec.makeRecord(
            type: .chapter,
            recordName: SyncRecordName.chapter(bookID: book.id, chapterSetID: book.id, index: 0),
            zoneID: CKRecordZone.ID(zoneName: "StoryCastLibraryV1"),
            payload: payload
        )

        try await SyncInboxApplier.stage(record: record, container: container)

        let verification = ModelContext(container)
        let chapters = try verification.fetch(FetchDescriptor<Chapter>())
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Alpha")
        XCTAssertEqual(chapters[0].endTime, 60, accuracy: 0.001)
        XCTAssertEqual(chapters[1].title, "Beta")
        XCTAssertEqual(chapters[1].endTime, 150, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
