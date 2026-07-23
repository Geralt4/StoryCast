import CloudKit
import Foundation
import SwiftData

enum CloudKitSyncEngineError: LocalizedError {
    case accountUnavailable(CKAccountStatus)
    case missingOutboxPayload(String)
    case missingLocalAsset(String)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable(let status):
            return "iCloud account is unavailable for sync (status \(status.rawValue))."
        case .missingOutboxPayload(let recordName):
            return "The local sync operation for \(recordName) has no payload."
        case .missingLocalAsset(let recordName):
            return "The local file for \(recordName) is unavailable."
        }
    }
}

@MainActor
protocol CloudSyncTransport: AnyObject {
    func prepareZoneAndFetchChanges() async throws
    func sendPendingChanges() async throws
    func fetchChanges() async throws
    func cancel() async
}

/// Explicit CloudKit transport for the local synchronization journal. The
/// SwiftData store stays local-only; this object is the sole CloudKit boundary.
@MainActor
final class CloudKitSyncEngine: NSObject, CloudSyncTransport, CKSyncEngineDelegate {
    static let zoneName = "StoryCastLibraryV1"

    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine!

    init(modelContainer: ModelContainer) throws {
        self.modelContainer = modelContainer
        self.cloudContainer = CKContainer(identifier: CloudSyncDefaults.containerIdentifier)
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName)
        super.init()

        let context = ModelContext(modelContainer)
        let runtime = try SyncRuntimeStore.runtime(in: context)
        SyncOutboxProcessor.recoverInterruptedOperations(in: context)
        try SyncRecordSystemFieldsStore.migrateLegacyFields(in: context)
        try SyncOutboxCompactor.compact(in: context)
        let stateSerialization = runtime.engineStateData.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(
            database: cloudContainer.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = false
        self.engine = CKSyncEngine(configuration)
        try context.save()
    }

    func prepareZoneAndFetchChanges() async throws {
        let accountStatus = try await cloudContainer.accountStatus()
        guard accountStatus == .available else {
            throw CloudKitSyncEngineError.accountUnavailable(accountStatus)
        }
        let currentUser = try await cloudContainer.userRecordID()
        let accountContext = ModelContext(modelContainer)
        try SyncAccountCoordinator.validate(accountIdentifier: currentUser.recordName, in: accountContext)

        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        try await engine.sendChanges()
        try await engine.fetchChanges()
        try await SyncInboxApplier.drain(container: modelContainer)
        try await retryUnstagedInboxAssets()
    }

    func sendPendingChanges() async throws {
        var maySendExistingPendingState = true

        for _ in 0..<50 {
            let addedCount = try scheduleReadyOperations()
            let hasPending = !engine.state.pendingRecordZoneChanges.isEmpty
            guard addedCount > 0 || (maySendExistingPendingState && hasPending) else { break }
            maySendExistingPendingState = false
            try await engine.sendChanges()
        }
    }

    func fetchChanges() async throws {
        try await engine.fetchChanges()
        try await SyncInboxApplier.drain(container: modelContainer)
        try await retryUnstagedInboxAssets()
    }

    func cancel() async {
        await engine.cancelOperations()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            persistEngineState(event.stateSerialization)

        case .accountChange(let event):
            handleAccountChange(event)

        case .fetchedDatabaseChanges:
            AppLogger.sync.debug("Fetched CloudKit database changes")

        case .fetchedRecordZoneChanges(let event):
            let accountContext = ModelContext(modelContainer)
            if (try? SyncAccountCoordinator.binding(in: accountContext).stateRaw) == "confirmationRequired" {
                AppLogger.sync.info("Ignored CloudKit changes until account merge is confirmed")
                return
            }
            for modification in event.modifications where modification.record.recordID.zoneID == zoneID {
                do {
                    try await SyncInboxApplier.stage(
                        record: modification.record,
                        container: modelContainer,
                        drainAfterStaging: false
                    )
                } catch {
                    recordSyncError(error.localizedDescription)
                    AppLogger.sync.error("Failed to apply CloudKit record: \(error.localizedDescription, privacy: .private)")
                }
            }
            do {
                try await SyncInboxApplier.drain(container: modelContainer)
                try await retryUnstagedInboxAssets()
            } catch {
                recordSyncError(error.localizedDescription)
                AppLogger.sync.error("Failed to drain CloudKit inbox: \(error.localizedDescription, privacy: .private)")
            }
            if !event.deletions.isEmpty {
                AppLogger.sync.info("Ignored \(event.deletions.count) physical record deletions; StoryCast uses tombstone records")
            }

        case .sentDatabaseChanges(let event):
            if let failure = event.failedZoneSaves.first {
                recordSyncError(userMessage(for: failure.error))
            }

        case .sentRecordZoneChanges(let event):
            await handleSentRecordChanges(event, syncEngine: syncEngine)

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                recordSyncError(userMessage(for: error))
            }

        case .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            AppLogger.sync.info("Received a newer CloudKit sync event that this version does not handle")
        }
    }

    private func retryUnstagedInboxAssets() async throws {
        let recordNames = SyncInboxApplier.retryableUnstagedAssetRecordNames(container: modelContainer)
        guard !recordNames.isEmpty else { return }

        for recordName in recordNames {
            let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            do {
                let record = try await cloudContainer.privateCloudDatabase.record(for: recordID)
                try await SyncInboxApplier.stage(
                    record: record,
                    container: modelContainer,
                    drainAfterStaging: false
                )
            } catch {
                recordSyncError(error.localizedDescription)
                AppLogger.sync.error("Failed to retry inbox asset \(recordName, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }

        try await SyncInboxApplier.drain(container: modelContainer)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        guard !pending.isEmpty else { return nil }

        let modelContext = ModelContext(modelContainer)
        do {
            let operations = try modelContext.fetch(FetchDescriptor<SyncOutboxOperation>())
            var recordsToSave: [CKRecord] = []
            var recordIDsToDelete: [CKRecord.ID] = []
            var rejectedChanges: [CKSyncEngine.PendingRecordZoneChange] = []

            for change in pending {
                switch change {
                case .saveRecord(let recordID):
                    guard let operation = operations.first(where: {
                        $0.subjectID == recordID.recordName && $0.stateRaw == "queued"
                    }) else {
                        rejectedChanges.append(change)
                        continue
                    }
                    do {
                        let record = try makeRecord(for: operation, in: modelContext)
                        SyncOutboxProcessor.markSending(operation)
                        recordsToSave.append(record)
                    } catch {
                        SyncOutboxProcessor.markRetry(operation, message: error.localizedDescription, retryAfter: nil)
                        recordSyncError(error.localizedDescription)
                        rejectedChanges.append(change)
                    }

                case .deleteRecord(let recordID):
                    guard let operation = operations.first(where: {
                        $0.subjectID == recordID.recordName && $0.stateRaw == "queued"
                    }) else {
                        rejectedChanges.append(change)
                        continue
                    }
                    SyncOutboxProcessor.markSending(operation)
                    recordIDsToDelete.append(recordID)

                @unknown default:
                    rejectedChanges.append(change)
                }
            }

            if !rejectedChanges.isEmpty {
                syncEngine.state.remove(pendingRecordZoneChanges: rejectedChanges)
            }
            try modelContext.save()
            guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(
                recordsToSave: recordsToSave,
                recordIDsToDelete: recordIDsToDelete,
                atomicByZone: false
            )
        } catch {
            recordSyncError(error.localizedDescription)
            return nil
        }
    }

    private func scheduleReadyOperations() throws -> Int {
        let context = ModelContext(modelContainer)
        let ready = try SyncOutboxProcessor.readyOperations(in: context)
        let pending = Set(engine.state.pendingRecordZoneChanges)
        var additions: [CKSyncEngine.PendingRecordZoneChange] = []

        for operation in ready {
            let recordID = CKRecord.ID(recordName: operation.subjectID, zoneID: zoneID)
            let change: CKSyncEngine.PendingRecordZoneChange
            switch SyncOutboxKind(rawValue: operation.kindRaw) {
            case .deleteRecord, .deleteAsset:
                change = .deleteRecord(recordID)
            case .saveRecord, .uploadAsset, nil:
                change = .saveRecord(recordID)
            }
            if !pending.contains(change) { additions.append(change) }
        }

        if !additions.isEmpty {
            engine.state.add(pendingRecordZoneChanges: additions)
        }
        return additions.count
    }

    private func makeRecord(for operation: SyncOutboxOperation, in context: ModelContext) throws -> CKRecord {
        guard let payloadData = operation.payloadData else {
            throw CloudKitSyncEngineError.missingOutboxPayload(operation.subjectID)
        }
        guard let kind = SyncEntityKind(rawValue: operation.subjectKindRaw) else {
            throw CloudSyncRecordCodecError.unsupportedRecordType(operation.subjectKindRaw)
        }

        switch kind {
        case .generation:
            return try makeRecord(.generation, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncGenerationPayload.self, from: payloadData), in: context)
        case .folder:
            return try makeRecord(.folder, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncFolderPayload.self, from: payloadData), in: context)
        case .book:
            return try makeRecord(.book, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncBookPayload.self, from: payloadData), in: context)
        case .chapter:
            return try makeRecord(.chapter, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncChapterPayload.self, from: payloadData), in: context)
        case .progress:
            return try makeRecord(.progress, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncProgressPayload.self, from: payloadData), in: context)
        case .tombstone:
            return try makeRecord(.tombstone, operation: operation, payload: CloudSyncRecordCodec.decodePayload(CloudSyncTombstonePayload.self, from: payloadData), in: context)
        case .asset:
            let payload = try CloudSyncRecordCodec.decodePayload(CloudSyncAssetPayload.self, from: payloadData)
            let assets = try context.fetch(FetchDescriptor<SyncAsset>())
            guard let asset = assets.first(where: { $0.id == payload.assetID }),
                  let relativePath = asset.localRelativePath else {
                throw CloudKitSyncEngineError.missingLocalAsset(operation.subjectID)
            }
            guard StorageCleanupCoordinator.isSafeRelativePath(relativePath) else {
                throw CloudKitSyncEngineError.missingLocalAsset(operation.subjectID)
            }
            let directoryURL = payload.kind == .audio
                ? StorageManager.shared.storyCastLibraryURL
                : StorageManager.shared.coverArtDirectoryURL
            let root = directoryURL.standardizedFileURL
            let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
            guard fileURL.deletingLastPathComponent() == root else {
                throw CloudKitSyncEngineError.missingLocalAsset(operation.subjectID)
            }
            asset.cloudStateRaw = SyncAssetCloudState.uploading.rawValue
            return try CloudSyncRecordCodec.makeAssetRecord(
                payload: payload,
                recordName: operation.subjectID,
                zoneID: zoneID,
                fileURL: fileURL,
                baseRecord: try SyncRecordSystemFieldsStore.record(for: operation.subjectID, in: context)
            )
        }
    }

    private func makeRecord<Payload: Encodable>(
        _ type: CloudSyncRecordType,
        operation: SyncOutboxOperation,
        payload: Payload,
        in context: ModelContext
    ) throws -> CKRecord {
        try CloudSyncRecordCodec.makeRecord(
            type: type,
            recordName: operation.subjectID,
            zoneID: zoneID,
            payload: payload,
            baseRecord: try SyncRecordSystemFieldsStore.record(for: operation.subjectID, in: context)
        )
    }

    private func handleSentRecordChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        let context = ModelContext(modelContainer)
        do {
            let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
            let assets = try context.fetch(FetchDescriptor<SyncAsset>())

            for record in event.savedRecords {
                if let operation = operations.first(where: {
                    $0.subjectID == record.recordID.recordName && $0.stateRaw == "sending"
                }) {
                    if let kind = SyncEntityKind(rawValue: operation.subjectKindRaw) {
                        try SyncRecordSystemFieldsStore.persist(record: record, kind: kind, in: context)
                    }
                    SyncOutboxProcessor.markSent(operation)
                    removeUploadMarker(recordName: record.recordID.recordName, in: context)
                    if operation.subjectKindRaw == SyncEntityKind.generation.rawValue,
                       let payloadData = operation.payloadData,
                       let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncGenerationPayload.self, from: payloadData),
                       let binding = try? SyncAccountCoordinator.binding(in: context) {
                        binding.boundGenerationID = payload.generationID.uuidString.lowercased()
                    }
                    if operation.subjectKindRaw == SyncEntityKind.asset.rawValue,
                       let payloadData = operation.payloadData,
                       let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetPayload.self, from: payloadData),
                       let asset = assets.first(where: { $0.id == payload.assetID }) {
                        asset.cloudStateRaw = SyncAssetCloudState.published.rawValue
                        asset.cloudRelativePath = payload.cloudRelativePath
                        asset.lastErrorMessage = nil
                    }
                }
            }

            for recordID in event.deletedRecordIDs {
                if let operation = operations.first(where: {
                    $0.subjectID == recordID.recordName && $0.stateRaw == "sending"
                }) {
                    SyncOutboxProcessor.markSent(operation)
                    ensureRetentionState(for: operation, in: context)
                }
            }

            for failure in event.failedRecordSaves {
                do {
                    try await markFailure(
                        failure.record.recordID,
                        error: failure.error,
                        operations: operations,
                        context: context,
                        syncEngine: syncEngine
                    )
                } catch {
                    recordSyncError(error.localizedDescription)
                }
            }
            for (recordID, error) in event.failedRecordDeletes {
                do {
                    try await markFailure(
                        recordID,
                        error: error,
                        operations: operations,
                        context: context,
                        syncEngine: syncEngine
                    )
                } catch {
                    recordSyncError(error.localizedDescription)
                }
            }
            try SyncOutboxCompactor.compact(in: context)
            try context.save()
        } catch {
            recordSyncError(error.localizedDescription)
        }
    }

    private func markFailure(
        _ recordID: CKRecord.ID,
        error: CKError,
        operations: [SyncOutboxOperation],
        context: ModelContext,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let operation = operations.first(where: {
            $0.subjectID == recordID.recordName && $0.stateRaw == "sending"
        }) else { return }
        if error.code == .unknownItem,
           operation.kindRaw == SyncOutboxKind.deleteAsset.rawValue || operation.kindRaw == SyncOutboxKind.deleteRecord.rawValue {
            SyncOutboxProcessor.markSent(operation)
            ensureRetentionState(for: operation, in: context)
            syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            return
        }
        if error.code == .serverRecordChanged,
           let serverRecord = error.serverRecord,
           let kind = SyncEntityKind(rawValue: operation.subjectKindRaw) {
            do {
                try await SyncInboxApplier.stage(record: serverRecord, container: modelContainer)
                let resolutionContext = ModelContext(modelContainer)
                let localStillWins = try resolutionContext.fetch(FetchDescriptor<SyncReplicaUploadMarker>())
                    .contains(where: { $0.recordName == recordID.recordName })
                if localStillWins && kind != .generation {
                    SyncOutboxProcessor.markRetry(operation, message: "Resolving a newer local change.", retryAfter: Date())
                } else {
                    SyncOutboxProcessor.markSent(operation)
                }
            } catch {
                try? SyncRecordSystemFieldsStore.persist(record: serverRecord, kind: kind, in: context)
                SyncOutboxProcessor.markRetry(operation, message: error.localizedDescription, retryAfter: Date())
            }
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID), .deleteRecord(recordID)])
            return
        }
        let retryAfter = error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
            ?? (error.code == .quotaExceeded ? Date().addingTimeInterval(3_600) : nil)
        let message = userMessage(for: error)
        SyncOutboxProcessor.markRetry(
            operation,
            message: message,
            retryAfter: retryAfter
        )
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID), .deleteRecord(recordID)])
        recordSyncError(message)
    }

    private func userMessage(for error: CKError) -> String {
        switch error.code {
        case .quotaExceeded:
            return "Your iCloud storage is full. Free some iCloud space, then retry sync."
        case .notAuthenticated:
            return "Sign in to iCloud to sync your imported library."
        case .networkUnavailable, .networkFailure:
            return "StoryCast could not reach iCloud. Check your connection and retry."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is temporarily busy. StoryCast will retry later."
        default:
            return error.localizedDescription
        }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        let context = ModelContext(modelContainer)
        do {
            let runtime = try SyncRuntimeStore.runtime(in: context)
            switch event.changeType {
            case .signIn(let currentUser):
                try SyncAccountCoordinator.validate(accountIdentifier: currentUser.recordName, in: context)
            case .signOut:
                runtime.accountIdentifier = nil
                runtime.activeModeRaw = SyncMode.disabled.rawValue
                runtime.lastErrorMessage = "Sign in to iCloud to sync your imported library."
            case .switchAccounts(_, let currentUser):
                try SyncAccountCoordinator.validate(accountIdentifier: currentUser.recordName, in: context)
            @unknown default:
                runtime.lastErrorMessage = "The iCloud account state changed. Retry sync."
            }
            runtime.updatedAt = Date()
            try context.save()
        } catch {
            if error is SyncAccountError {
                AppLogger.sync.info("iCloud account merge confirmation is required")
                SyncController.shared.accountConfirmationBecameRequired(container: modelContainer)
                Task { await engine.cancelOperations() }
            } else {
                recordSyncError(error.localizedDescription)
            }
        }
    }

    private func persistEngineState(_ stateSerialization: CKSyncEngine.State.Serialization) {
        let context = ModelContext(modelContainer)
        do {
            let runtime = try SyncRuntimeStore.runtime(in: context)
            runtime.engineStateData = try JSONEncoder().encode(stateSerialization)
            runtime.updatedAt = Date()
            try context.save()
        } catch {
            AppLogger.sync.error("Failed to persist CKSyncEngine state: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func recordSyncError(_ message: String) {
        let context = ModelContext(modelContainer)
        do {
            let runtime = try SyncRuntimeStore.runtime(in: context)
            runtime.lastErrorMessage = message
            runtime.updatedAt = Date()
            try context.save()
        } catch {
            AppLogger.sync.error("Failed to persist sync error: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func removeUploadMarker(recordName: String, in context: ModelContext) {
        guard let markers = try? context.fetch(FetchDescriptor<SyncReplicaUploadMarker>()) else { return }
        for marker in markers where marker.recordName == recordName { context.delete(marker) }
    }

    private func ensureRetentionState(for operation: SyncOutboxOperation, in context: ModelContext) {
        guard operation.kindRaw == SyncOutboxKind.deleteAsset.rawValue,
              let data = operation.payloadData,
              let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetDeletionPayload.self, from: data),
              let existing = try? context.fetch(FetchDescriptor<SyncAssetRetentionState>())
        else { return }
        if !existing.contains(where: { $0.assetID == payload.assetID }) {
            context.insert(SyncAssetRetentionState(assetID: payload.assetID))
        }
    }
}
