import Foundation
import SwiftData

/// Local-only synchronization journal. CloudKit records are encoded explicitly
/// from these models so Audiobookshelf entities never enter iCloud by accident.
@Model
final class SyncRuntime {
    @Attribute(.unique) var id: String
    var desiredModeRaw: String
    var activeModeRaw: String
    var generationID: String?
    var accountIdentifier: String?
    var engineStateData: Data?
    var lastSuccessfulSyncAt: Date?
    var lastErrorMessage: String?
    var updatedAt: Date

    init(
        id: String = "runtime",
        desiredModeRaw: String = "disabled",
        activeModeRaw: String = "disabled",
        generationID: String? = nil,
        accountIdentifier: String? = nil,
        engineStateData: Data? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        lastErrorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.desiredModeRaw = desiredModeRaw
        self.activeModeRaw = activeModeRaw
        self.generationID = generationID
        self.accountIdentifier = accountIdentifier
        self.engineStateData = engineStateData
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastErrorMessage = lastErrorMessage
        self.updatedAt = updatedAt
    }
}

/// Maps a local imported-library entity to its explicit CloudKit record state.
@Model
final class SyncEntityState {
    @Attribute(.unique) var id: String
    var entityKindRaw: String
    var localEntityID: String
    var recordName: String
    var revision: Int64
    var modifiedAt: Date
    var deviceID: String
    var contentDigest: String?
    var recordSystemFields: Data?

    init(
        id: String,
        entityKindRaw: String,
        localEntityID: String,
        recordName: String,
        revision: Int64 = 0,
        modifiedAt: Date = Date(),
        deviceID: String,
        contentDigest: String? = nil,
        recordSystemFields: Data? = nil
    ) {
        self.id = id
        self.entityKindRaw = entityKindRaw
        self.localEntityID = localEntityID
        self.recordName = recordName
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.contentDigest = contentDigest
        self.recordSystemFields = recordSystemFields
    }
}

/// Tracks one local and cloud replica of an imported audio or cover-art asset.
@Model
final class SyncAsset {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var kindRaw: String
    var contentRevision: Int64
    var originalFileName: String
    var pathExtension: String
    var contentTypeIdentifier: String
    var byteCount: Int64
    var sha256Hex: String
    var localRelativePath: String?
    var cloudRelativePath: String?
    var localStateRaw: String
    var cloudStateRaw: String
    var lastVerifiedAt: Date?
    var retryAfter: Date?
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        bookID: UUID,
        kindRaw: String,
        contentRevision: Int64 = 1,
        originalFileName: String,
        pathExtension: String,
        contentTypeIdentifier: String,
        byteCount: Int64,
        sha256Hex: String,
        localRelativePath: String? = nil,
        cloudRelativePath: String? = nil,
        localStateRaw: String = "missing",
        cloudStateRaw: String = "notScheduled",
        lastVerifiedAt: Date? = nil,
        retryAfter: Date? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.kindRaw = kindRaw
        self.contentRevision = contentRevision
        self.originalFileName = originalFileName
        self.pathExtension = pathExtension
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.localRelativePath = localRelativePath
        self.cloudRelativePath = cloudRelativePath
        self.localStateRaw = localStateRaw
        self.cloudStateRaw = cloudStateRaw
        self.lastVerifiedAt = lastVerifiedAt
        self.retryAfter = retryAfter
        self.lastErrorMessage = lastErrorMessage
    }
}

/// Durable local outbox. Payload and dependency data are intentionally opaque
/// so CloudKit-specific record encoding stays outside the SwiftData schema.
@Model
final class SyncOutboxOperation {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var subjectKindRaw: String
    var subjectID: String
    var payloadData: Data?
    var dependencyData: Data?
    var stateRaw: String
    var createdAt: Date
    var nextRetryAt: Date?
    var attemptCount: Int
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        kindRaw: String,
        subjectKindRaw: String,
        subjectID: String,
        payloadData: Data? = nil,
        dependencyData: Data? = nil,
        stateRaw: String = "queued",
        createdAt: Date = Date(),
        nextRetryAt: Date? = nil,
        attemptCount: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.subjectKindRaw = subjectKindRaw
        self.subjectID = subjectID
        self.payloadData = payloadData
        self.dependencyData = dependencyData
        self.stateRaw = stateRaw
        self.createdAt = createdAt
        self.nextRetryAt = nextRetryAt
        self.attemptCount = attemptCount
        self.lastErrorMessage = lastErrorMessage
    }
}

/// Holds an incoming record until all dependent local records and assets exist.
@Model
final class SyncInboxRecord {
    @Attribute(.unique) var id: String
    var recordType: String
    var payloadData: Data
    var receivedAt: Date
    var stateRaw: String

    init(
        id: String,
        recordType: String,
        payloadData: Data,
        receivedAt: Date = Date(),
        stateRaw: String = "pending"
    ) {
        self.id = id
        self.recordType = recordType
        self.payloadData = payloadData
        self.receivedAt = receivedAt
        self.stateRaw = stateRaw
    }
}

/// Stores this installation's progress action for an imported book. Each device
/// owns a separate head so conflict resolution remains deterministic.
@Model
final class SyncProgressHead {
    @Attribute(.unique) var id: String
    var bookID: UUID
    var deviceID: String
    var actionID: UUID
    var position: Double
    var actionAt: Date
    var sequence: Int64
    var actionKindRaw: String

    init(
        id: String,
        bookID: UUID,
        deviceID: String,
        actionID: UUID = UUID(),
        position: Double,
        actionAt: Date,
        sequence: Int64,
        actionKindRaw: String
    ) {
        self.id = id
        self.bookID = bookID
        self.deviceID = deviceID
        self.actionID = actionID
        self.position = position
        self.actionAt = actionAt
        self.sequence = sequence
        self.actionKindRaw = actionKindRaw
    }
}

/// Prevents an offline device from recreating an imported book deleted elsewhere.
@Model
final class SyncTombstone {
    @Attribute(.unique) var id: String
    var entityKindRaw: String
    var entityID: String
    var deletedAt: Date
    var revision: Int64
    var deviceID: String

    init(
        id: String,
        entityKindRaw: String,
        entityID: String,
        deletedAt: Date = Date(),
        revision: Int64,
        deviceID: String
    ) {
        self.id = id
        self.entityKindRaw = entityKindRaw
        self.entityID = entityID
        self.deletedAt = deletedAt
        self.revision = revision
        self.deviceID = deviceID
    }
}

/// Makes local library auditing and migration restartable rather than relying on
/// one-shot preference flags.
@Model
final class SyncMigrationJournal {
    @Attribute(.unique) var id: String
    var phaseRaw: String
    var sourceStoreVersion: String
    var lastProcessedEntityID: String?
    var completedAt: Date?
    var verificationError: String?
    var updatedAt: Date

    init(
        id: String = "initialLibraryAudit",
        phaseRaw: String = "notStarted",
        sourceStoreVersion: String = "4.0.0",
        lastProcessedEntityID: String? = nil,
        completedAt: Date? = nil,
        verificationError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.phaseRaw = phaseRaw
        self.sourceStoreVersion = sourceStoreVersion
        self.lastProcessedEntityID = lastProcessedEntityID
        self.completedAt = completedAt
        self.verificationError = verificationError
        self.updatedAt = updatedAt
    }
}
@Model
final class SyncAccountBinding {
    @Attribute(.unique) var id: String
    var confirmedAccountIdentifier: String?
    var pendingAccountIdentifier: String?
    var boundGenerationID: String?
    var stateRaw: String
    var updatedAt: Date

    init(id: String = "accountBinding", confirmedAccountIdentifier: String? = nil,
         pendingAccountIdentifier: String? = nil, boundGenerationID: String? = nil,
         stateRaw: String = "unbound", updatedAt: Date = Date()) {
        self.id = id
        self.confirmedAccountIdentifier = confirmedAccountIdentifier
        self.pendingAccountIdentifier = pendingAccountIdentifier
        self.boundGenerationID = boundGenerationID
        self.stateRaw = stateRaw
        self.updatedAt = updatedAt
    }
}

@Model
final class SyncCloudRecordState {
    @Attribute(.unique) var recordName: String
    var entityKindRaw: String
    var recordSystemFields: Data
    var updatedAt: Date

    init(recordName: String, entityKindRaw: String, recordSystemFields: Data, updatedAt: Date = Date()) {
        self.recordName = recordName
        self.entityKindRaw = entityKindRaw
        self.recordSystemFields = recordSystemFields
        self.updatedAt = updatedAt
    }
}

@Model
final class SyncReplicaUploadMarker {
    @Attribute(.unique) var id: String
    var recordName: String
    var reasonRaw: String
    var createdAt: Date

    init(id: String, recordName: String, reasonRaw: String, createdAt: Date = Date()) {
        self.id = id
        self.recordName = recordName
        self.reasonRaw = reasonRaw
        self.createdAt = createdAt
    }
}

@Model
final class SyncAssetRetentionState {
    @Attribute(.unique) var id: String
    var assetID: UUID
    var prunedThroughRevision: Int64

    init(assetID: UUID, prunedThroughRevision: Int64 = 0) {
        self.id = assetID.uuidString.lowercased()
        self.assetID = assetID
        self.prunedThroughRevision = prunedThroughRevision
    }
}
@Model
final class StorageCleanupJournalEntry {
    @Attribute(.unique) var id: UUID
    var locationRaw: String
    var relativePath: String
    var createdAt: Date
    var attemptCount: Int
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        locationRaw: String,
        relativePath: String,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.locationRaw = locationRaw
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastErrorMessage = lastErrorMessage
    }
}

@Model
final class SyncLocalMutation {
    @Attribute(.unique) var id: String
    var subjectKindRaw: String
    var localEntityID: String
    var recordName: String?
    var version: Int64
    var intentData: Data?
    var changedAt: Date
    var stateRaw: String
    var operationID: UUID?
    var materializedVersion: Int64
    var reasonRaw: String

    init(
        id: String,
        subjectKindRaw: String,
        localEntityID: String,
        recordName: String? = nil,
        version: Int64 = 1,
        intentData: Data? = nil,
        changedAt: Date = Date(),
        stateRaw: String = "dirty",
        operationID: UUID? = nil,
        materializedVersion: Int64 = 0,
        reasonRaw: String
    ) {
        self.id = id
        self.subjectKindRaw = subjectKindRaw
        self.localEntityID = localEntityID
        self.recordName = recordName
        self.version = version
        self.intentData = intentData
        self.changedAt = changedAt
        self.stateRaw = stateRaw
        self.operationID = operationID
        self.materializedVersion = materializedVersion
        self.reasonRaw = reasonRaw
    }
}

@Model
final class SyncInboxRetryState {
    @Attribute(.unique) var recordName: String
    var deliveryFingerprint: String
    var attemptCount: Int
    var nextRetryAt: Date?
    var lastAttemptAt: Date?
    var lastErrorMessage: String?
    var stagedAssetRelativePath: String?
    var claimID: UUID?
    var updatedAt: Date

    init(
        recordName: String,
        deliveryFingerprint: String,
        attemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorMessage: String? = nil,
        stagedAssetRelativePath: String? = nil,
        claimID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.recordName = recordName
        self.deliveryFingerprint = deliveryFingerprint
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorMessage = lastErrorMessage
        self.stagedAssetRelativePath = stagedAssetRelativePath
        self.claimID = claimID
        self.updatedAt = updatedAt
    }
}

@Model
final class ServerRemovalJournalEntry {
    @Attribute(.unique) var serverID: UUID
    var normalizedURL: String
    var displayName: String
    var previousIsActive: Bool
    var phaseRaw: String
    var createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var lastErrorMessage: String?

    init(
        serverID: UUID,
        normalizedURL: String,
        displayName: String,
        previousIsActive: Bool,
        phaseRaw: String = "prepared",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.serverID = serverID
        self.normalizedURL = normalizedURL
        self.displayName = displayName
        self.previousIsActive = previousIsActive
        self.phaseRaw = phaseRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.lastErrorMessage = lastErrorMessage
    }
}
