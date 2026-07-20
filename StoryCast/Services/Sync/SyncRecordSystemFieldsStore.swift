import CloudKit
import Foundation
import SwiftData

/// Persists CloudKit change tags independently from user-facing models. This
/// lets later updates modify existing records instead of recreating them with
/// no server version information.
@MainActor
enum SyncRecordSystemFieldsStore {
    static func migrateLegacyFields(in context: ModelContext) throws {
        let legacy = try context.fetch(FetchDescriptor<SyncEntityState>())
            .filter { $0.recordSystemFields != nil }
        for group in Dictionary(grouping: legacy, by: \.recordName).values {
            let records = group.compactMap { state -> CKRecord? in
                guard let data = state.recordSystemFields else { return nil }
                return try? CloudSyncRecordCodec.record(fromSystemFields: data)
            }
            if let newest = records.max(by: {
                ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
            }), let kind = group.compactMap({ SyncEntityKind(rawValue: $0.entityKindRaw) }).first {
                try persist(record: newest, kind: kind, in: context)
            }
            for state in group { state.recordSystemFields = nil }
        }
    }

    static func record(for recordName: String, in context: ModelContext) throws -> CKRecord? {
        if let data = try context.fetch(FetchDescriptor<SyncCloudRecordState>())
            .first(where: { $0.recordName == recordName })?.recordSystemFields {
            return try CloudSyncRecordCodec.record(fromSystemFields: data)
        }
        return nil
    }

    static func persist(record: CKRecord, kind: SyncEntityKind, in context: ModelContext) throws {
        let name = record.recordID.recordName
        let records = try context.fetch(FetchDescriptor<SyncCloudRecordState>())
        if let state = records.first(where: { $0.recordName == name }) {
            state.entityKindRaw = kind.rawValue
            state.recordSystemFields = CloudSyncRecordCodec.systemFieldsData(from: record)
            state.updatedAt = record.modificationDate ?? Date()
        } else {
            context.insert(SyncCloudRecordState(
                recordName: name, entityKindRaw: kind.rawValue,
                recordSystemFields: CloudSyncRecordCodec.systemFieldsData(from: record),
                updatedAt: record.modificationDate ?? Date()
            ))
        }
    }
}
