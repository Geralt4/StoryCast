import CloudKit
import XCTest
@testable import StoryCast

final class CloudSyncRecordCodecTests: XCTestCase {
    func testSystemFieldsRoundTripPreservesRecordIdentity() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        let recordID = CKRecord.ID(recordName: "book/example", zoneID: zoneID)
        let record = CKRecord(recordType: CloudSyncRecordType.book.rawValue, recordID: recordID)

        let data = CloudSyncRecordCodec.systemFieldsData(from: record)
        let restored = try CloudSyncRecordCodec.record(fromSystemFields: data)

        XCTAssertEqual(restored.recordID, recordID)
        XCTAssertEqual(restored.recordType, CloudSyncRecordType.book.rawValue)
    }

    func testAssetRecordCarriesFileAndRoundTripsMetadata() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoryCastAssetCodec-\(UUID().uuidString).m4b")
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let payload = CloudSyncAssetPayload(
            assetID: UUID(),
            bookID: UUID(),
            kind: .audio,
            contentRevision: 2,
            originalFileName: "My Book.m4b",
            cloudRelativePath: "assets/book/audio-2.m4b",
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 4,
            sha256Hex: "example-digest",
            readyAt: Date(timeIntervalSince1970: 1_000)
        )
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        let record = try CloudSyncRecordCodec.makeAssetRecord(
            payload: payload,
            recordName: SyncRecordName.asset(payload.assetID, revision: payload.contentRevision),
            zoneID: zoneID,
            fileURL: temporaryURL
        )

        XCTAssertEqual(CloudSyncRecordCodec.assetFileURL(from: record)?.standardizedFileURL, temporaryURL.standardizedFileURL)
        XCTAssertEqual(
            try CloudSyncRecordCodec.decode(CloudSyncAssetPayload.self, from: record, expectedType: .asset),
            payload
        )
    }

    func testBookPayloadRoundTripsWithoutAudiobookshelfFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        let bookID = UUID()
        let payload = CloudSyncBookPayload(
            bookID: bookID,
            title: "Imported Book",
            author: "Author",
            duration: 120,
            folderID: UUID(),
            audioAssetID: UUID(),
            coverArtAssetID: UUID(),
            chapterSetID: UUID(),
            revision: 3,
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            deviceID: "device-a"
        )

        let record = try CloudSyncRecordCodec.makeRecord(
            type: .book,
            recordName: SyncRecordName.book(bookID),
            zoneID: zoneID,
            payload: payload,
            updatedAt: payload.modifiedAt
        )
        let decoded = try CloudSyncRecordCodec.decode(
            CloudSyncBookPayload.self,
            from: record,
            expectedType: .book
        )

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(record.recordType, CloudSyncRecordType.book.rawValue)
        XCTAssertNil(record["remoteItemId"])
        XCTAssertNil(record["serverId"])
        XCTAssertNil(record["localCachePath"])
    }

    func testDecodeRejectsUnexpectedRecordType() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StoryCastLibraryV1")
        let payload = CloudSyncGenerationPayload(
            generationID: UUID(),
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let record = try CloudSyncRecordCodec.makeRecord(
            type: .generation,
            recordName: SyncRecordName.generation(),
            zoneID: zoneID,
            payload: payload
        )

        XCTAssertThrowsError(
            try CloudSyncRecordCodec.decode(
                CloudSyncBookPayload.self,
                from: record,
                expectedType: .book
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CloudSyncRecordCodecError.unsupportedRecordType(CloudSyncRecordType.generation.rawValue).localizedDescription
            )
        }
    }
}
