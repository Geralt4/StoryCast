import CloudKit
import Foundation

nonisolated enum CloudSyncRecordType: String, CaseIterable, Sendable {
    case generation = "SCLibraryGenerationV1"
    case book = "SCBookV1"
    case folder = "SCFolderV1"
    case chapter = "SCChapterV1"
    case asset = "SCAssetV1"
    case progress = "SCProgressHeadV1"
    case tombstone = "SCTombstoneV1"
}

private nonisolated enum CloudSyncRecordField {
    static let schemaVersion = "schemaVersion"
    static let payload = "payload"
    static let updatedAt = "updatedAt"
    static let asset = "asset"
}

nonisolated enum CloudSyncRecordCodecError: LocalizedError {
    case unsupportedRecordType(String)
    case missingPayload(recordName: String)
    case invalidPayload(recordName: String, underlying: Error)
    case invalidSystemFields

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordType(let type):
            return "Unsupported StoryCast sync record type: \(type)"
        case .missingPayload(let name):
            return "Sync record \(name) is missing its payload"
        case .invalidPayload(let name, let error):
            return "Sync record \(name) has an invalid payload: \(error.localizedDescription)"
        case .invalidSystemFields:
            return "A saved CloudKit record token is invalid."
        }
    }
}

nonisolated struct CloudSyncGenerationPayload: Codable, Equatable, Sendable {
    let generationID: UUID
    let schemaVersion: Int
    let createdAt: Date
}

nonisolated struct CloudSyncBookPayload: Codable, Equatable, Sendable {
    let bookID: UUID
    let title: String
    let author: String?
    let duration: Double
    let folderID: UUID?
    let audioAssetID: UUID
    let coverArtAssetID: UUID?
    var audioAssetRevision: Int64? = nil
    var coverArtAssetRevision: Int64? = nil
    let chapterSetID: UUID
    let revision: Int64
    let modifiedAt: Date
    let deviceID: String
}

nonisolated struct CloudSyncFolderPayload: Codable, Equatable, Sendable {
    let folderID: UUID
    let name: String
    let isSystem: Bool
    let sortOrder: Int
    let revision: Int64
    let modifiedAt: Date
    let deviceID: String
}

nonisolated struct CloudSyncChapterPayload: Codable, Equatable, Sendable {
    let bookID: UUID
    let chapterSetID: UUID
    let index: Int
    let title: String
    let startTime: Double
    let endTime: Double
    let sourceRaw: String
    let revision: Int64
    let modifiedAt: Date
    let deviceID: String
}

nonisolated struct CloudSyncAssetPayload: Codable, Equatable, Sendable {
    let assetID: UUID
    let bookID: UUID
    let kind: SyncAssetKind
    let contentRevision: Int64
    let originalFileName: String
    let cloudRelativePath: String
    let pathExtension: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String
    let readyAt: Date
    var deviceID: String? = nil
}

nonisolated struct CloudSyncAssetDeletionPayload: Codable, Equatable, Sendable {
    let assetID: UUID
    let revision: Int64
}

nonisolated struct CloudSyncProgressPayload: Codable, Equatable, Sendable {
    let action: SyncProgressAction
}

nonisolated struct CloudSyncTombstonePayload: Codable, Equatable, Sendable {
    let entityKind: SyncEntityKind
    let entityID: String
    let deletedAt: Date
    let revision: Int64
    let deviceID: String
}

/// Uses one stable JSON payload field per record. This keeps the production
/// CloudKit schema additive and makes local validation independent of Core Data.
nonisolated enum CloudSyncRecordCodec {
    static let schemaVersion = 2

    static func makeRecord<Payload: Encodable>(
        type: CloudSyncRecordType,
        recordName: String,
        zoneID: CKRecordZone.ID,
        payload: Payload,
        updatedAt: Date = Date(),
        baseRecord: CKRecord? = nil
    ) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        if let baseRecord,
           baseRecord.recordType == type.rawValue,
           baseRecord.recordID == recordID {
            record = baseRecord
        } else {
            record = CKRecord(recordType: type.rawValue, recordID: recordID)
        }
        record[CloudSyncRecordField.schemaVersion] = schemaVersion as NSNumber
        record[CloudSyncRecordField.payload] = try encode(payload) as NSData
        record[CloudSyncRecordField.updatedAt] = updatedAt as NSDate
        return record
    }

    static func decode<Payload: Decodable>(
        _ payloadType: Payload.Type,
        from record: CKRecord,
        expectedType: CloudSyncRecordType
    ) throws -> Payload {
        guard record.recordType == expectedType.rawValue else {
            throw CloudSyncRecordCodecError.unsupportedRecordType(record.recordType)
        }
        guard let data = record[CloudSyncRecordField.payload] as? Data else {
            throw CloudSyncRecordCodecError.missingPayload(recordName: record.recordID.recordName)
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            throw CloudSyncRecordCodecError.invalidPayload(recordName: record.recordID.recordName, underlying: error)
        }
    }

    static func makeAssetRecord(
        payload: CloudSyncAssetPayload,
        recordName: String,
        zoneID: CKRecordZone.ID,
        fileURL: URL,
        baseRecord: CKRecord? = nil
    ) throws -> CKRecord {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        let record = try makeRecord(
            type: .asset,
            recordName: recordName,
            zoneID: zoneID,
            payload: payload,
            updatedAt: payload.readyAt,
            baseRecord: baseRecord
        )
        record[CloudSyncRecordField.asset] = CKAsset(fileURL: fileURL)
        return record
    }

    static func assetFileURL(from record: CKRecord) -> URL? {
        (record[CloudSyncRecordField.asset] as? CKAsset)?.fileURL
    }

    static func payloadData(from record: CKRecord) throws -> Data {
        guard let data = record[CloudSyncRecordField.payload] as? Data else {
            throw CloudSyncRecordCodecError.missingPayload(recordName: record.recordID.recordName)
        }
        guard data.count <= 1_000_000 else {
            throw CloudSyncRecordCodecError.invalidPayload(recordName: record.recordID.recordName, underlying: NSError(domain: "CloudSyncRecordCodec", code: -1, userInfo: [NSLocalizedDescriptionKey: "Payload exceeds 1 MB size limit"]))
        }
        return data
    }

    static func systemFieldsData(from record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func record(fromSystemFields data: Data) throws -> CKRecord {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else {
            throw CloudSyncRecordCodecError.invalidSystemFields
        }
        return record
    }

    static func encodePayload<Payload: Encodable>(_ payload: Payload) throws -> Data {
        try encode(payload)
    }

    static func decodePayload<Payload: Decodable>(_ payloadType: Payload.Type, from data: Data) throws -> Payload {
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            throw CloudSyncRecordCodecError.invalidPayload(recordName: "local-outbox", underlying: error)
        }
    }

    private static func encode<Payload: Encodable>(_ payload: Payload) throws -> Data {
        try encoder.encode(payload)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
