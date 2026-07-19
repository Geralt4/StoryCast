import CloudKit
import Foundation
import SwiftData

/// Persists CloudKit change tags independently from user-facing models. This
/// lets later updates modify existing records instead of recreating them with
/// no server version information.
@MainActor
enum SyncRecordSystemFieldsStore {
    static func record(for recordName: String, in context: ModelContext) throws -> CKRecord? {
        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        guard let data = states.first(where: {
            $0.recordName == recordName && $0.recordSystemFields != nil
        })?.recordSystemFields else { return nil }
        return try CloudSyncRecordCodec.record(fromSystemFields: data)
    }

    static func persist(record: CKRecord, kind: SyncEntityKind, in context: ModelContext) throws {
        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        let state = states.first(where: { $0.recordName == record.recordID.recordName }) ?? {
            let state = SyncEntityState(
                id: "record:\(record.recordID.recordName)",
                entityKindRaw: kind.rawValue,
                localEntityID: record.recordID.recordName,
                recordName: record.recordID.recordName,
                deviceID: "cloud"
            )
            context.insert(state)
            return state
        }()
        state.recordSystemFields = CloudSyncRecordCodec.systemFieldsData(from: record)
    }
}
