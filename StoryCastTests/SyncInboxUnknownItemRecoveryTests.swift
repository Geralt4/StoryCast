import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import StoryCast

@MainActor
final class SyncInboxUnknownItemRecoveryTests: XCTestCase {
    func testUnknownItemOnInboxAssetRetryDiscardsStaleRowAndDoesNotFailSync() async throws {
        let container = try makeContainer()
        let assetID = UUID()
        let recordName = SyncRecordName.asset(assetID, revision: 1)
        let payload = CloudSyncAssetPayload(
            assetID: assetID,
            bookID: UUID(),
            kind: .audio,
            contentRevision: 1,
            originalFileName: "superseded.m4b",
            cloudRelativePath: "assets/superseded.m4b",
            pathExtension: "m4b",
            contentTypeIdentifier: "public.audiovisual-content",
            byteCount: 1,
            sha256Hex: "digest",
            readyAt: Date()
        )
        let context = ModelContext(container)
        context.insert(SyncInboxRecord(
            id: recordName,
            recordType: CloudSyncRecordType.asset.rawValue,
            payloadData: try CloudSyncRecordCodec.encodePayload(payload)
        ))
        context.insert(SyncInboxRetryState(
            recordName: recordName,
            deliveryFingerprint: "fingerprint",
            nextRetryAt: .distantPast
        ))
        try context.save()
        XCTAssertEqual(SyncInboxApplier.retryableUnstagedAssetRecordNames(container: container), [recordName])

        let engine = try CloudKitSyncEngine(modelContainer: container)
        engine.recordFetcher = DeletedRecordFetcher()

        try await engine.retryUnstagedInboxAssets()

        let verification = ModelContext(container)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<SyncInboxRecord>()).isEmpty,
            "A stale inbox row whose CloudKit record was deleted must be discarded."
        )
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<SyncInboxRetryState>()).isEmpty,
            "The retry state of a discarded stale inbox row must be removed."
        )
        XCTAssertTrue(
            SyncInboxApplier.retryableUnstagedAssetRecordNames(container: container).isEmpty,
            "A discarded stale inbox row must not be retried again."
        )
        let runtime = try SyncRuntimeStore.runtime(in: verification)
        XCTAssertNil(
            runtime.lastErrorMessage,
            "A pruned CloudKit record is not a sync failure; the send side treats unknownItem as success too."
        )
    }

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

private final class DeletedRecordFetcher: CloudRecordFetching {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        throw CKError(.unknownItem)
    }
}