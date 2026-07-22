import Combine
import Foundation
import SwiftData

/// Owns the user-facing sync lifecycle and the durable local journal. Network
/// work is delegated through `CloudSyncTransport` so controller behavior can be
/// tested without contacting iCloud.
@MainActor
final class SyncController: ObservableObject {
    typealias TransportFactory = (ModelContainer) throws -> any CloudSyncTransport

    static let shared = SyncController()

    @Published private(set) var status: SyncStatus = .disabled

    private let transportFactory: TransportFactory
    private var transport: (any CloudSyncTransport)?
    private var didBootstrap = false
    private var isSynchronizing = false
    private var syncRequestedWhileRunning = false
    private var auditRequestedWhileRunning = false

    init(transportFactory: @escaping TransportFactory = { try CloudKitSyncEngine(modelContainer: $0) }) {
        self.transportFactory = transportFactory
    }

    func bootstrapIfNeeded(container: ModelContainer) {
        guard !didBootstrap else { return }

        do {
            let context = ModelContext(container)
            let runtime = try SyncRuntimeStore.runtime(in: context)
            let optedIn = UserDefaults.standard.bool(forKey: CloudSyncDefaults.iCloudSyncEnabledKey)
                || runtime.desiredModeRaw == SyncMode.enabled.rawValue
            if optedIn {
                runtime.desiredModeRaw = SyncMode.enabled.rawValue
                UserDefaults.standard.set(true, forKey: CloudSyncDefaults.iCloudSyncEnabledKey)
                try context.save()
            }
            didBootstrap = true
            status = status(for: runtime)
            if try SyncAccountCoordinator.binding(in: context).stateRaw == "confirmationRequired" {
                status = SyncStatus(mode: .enabled, activity: .accountConfirmationRequired, lastSuccessfulSyncAt: runtime.lastSuccessfulSyncAt)
            }

            if optedIn {
                Task { [weak self] in
                    await self?.synchronize(container: container, auditLibrary: true)
                }
            }
        } catch {
            publishFailure(error, container: container)
        }
    }

    func setEnabled(_ enabled: Bool, container: ModelContainer) async {
        UserDefaults.standard.set(enabled, forKey: CloudSyncDefaults.iCloudSyncEnabledKey)

        if enabled {
            do {
                try setDesiredMode(.enabled, container: container)
                await synchronize(container: container, auditLibrary: true)
            } catch {
                publishFailure(error, container: container)
            }
        } else {
            await disable(container: container)
        }
    }

    func setDesiredMode(_ mode: SyncMode, container: ModelContainer) throws {
        let context = ModelContext(container)
        let runtime = try SyncRuntimeStore.runtime(in: context)
        runtime.desiredModeRaw = mode.rawValue
        runtime.updatedAt = Date()

        if mode == .disabled {
            runtime.activeModeRaw = SyncMode.disabled.rawValue
            runtime.lastErrorMessage = nil
        }

        try context.save()
        status = status(for: runtime)
    }

    func synchronizeIfEnabled(container: ModelContainer, auditLibrary: Bool = false) async {
        let context = ModelContext(container)
        guard let runtime = try? SyncRuntimeStore.runtime(in: context),
              runtime.desiredModeRaw == SyncMode.enabled.rawValue else { return }
        await synchronize(container: container, auditLibrary: auditLibrary)
    }

    func retry(container: ModelContainer) async {
        let context = ModelContext(container)
        do {
            try SyncOutboxProcessor.resetRetries(in: context)
            let runtime = try SyncRuntimeStore.runtime(in: context)
            runtime.lastErrorMessage = nil
            runtime.updatedAt = Date()
            try context.save()
        } catch {
            publishFailure(error, container: container)
            return
        }
        await synchronize(container: container, auditLibrary: true)
    }

    @discardableResult
    func prepareLocalLibraryForSync(container: ModelContainer) async -> SyncLibraryAuditResult? {
        status = SyncStatus(mode: .enabled, activity: .preparing, lastSuccessfulSyncAt: status.lastSuccessfulSyncAt)

        do {
            let deviceID = try await SyncDeviceIdentity.shared.identifier()
            let result = await SyncLibraryAuditor.audit(container: container, deviceID: deviceID)
            if result.failedAssetCount > 0 || result.missingAssetCount > 0 {
                status = SyncStatus(
                    mode: .enabled,
                    activity: .waiting(reason: "Some local files need attention before they can sync."),
                    lastSuccessfulSyncAt: status.lastSuccessfulSyncAt
                )
            }
            return result
        } catch {
            publishFailure(error, container: container)
            return nil
        }
    }

    func recordProgress(
        bookID: UUID,
        position: Double,
        actionKind: String,
        container: ModelContainer
    ) async {
        guard position.isFinite, position >= 0 else { return }
        let context = ModelContext(container)
        guard let runtime = try? SyncRuntimeStore.runtime(in: context),
              runtime.desiredModeRaw == SyncMode.enabled.rawValue else { return }

        do {
            let deviceID = try await SyncDeviceIdentity.shared.identifier()

            let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
            let isTombstoned = tombstones.contains {
                $0.entityKindRaw == SyncEntityKind.book.rawValue && $0.entityID.lowercased() == bookID.uuidString.lowercased()
            }
            guard !isTombstoned else { return }

            let books = try context.fetch(FetchDescriptor<Book>())
            guard books.contains(where: { $0.id == bookID && !$0.isRemote }) else { return }

            let recordName = SyncRecordName.progress(bookID: bookID, deviceID: deviceID)
            let heads = try context.fetch(FetchDescriptor<SyncProgressHead>())
            let head = heads.first(where: { $0.id == recordName }) ?? {
                let head = SyncProgressHead(
                    id: recordName,
                    bookID: bookID,
                    deviceID: deviceID,
                    position: position,
                    actionAt: Date(),
                    sequence: 0,
                    actionKindRaw: actionKind
                )
                context.insert(head)
                return head
            }()
            head.actionID = UUID()
            head.position = position
            head.actionAt = Date()
            head.sequence += 1
            head.actionKindRaw = actionKind

            let action = SyncProgressAction(
                bookID: bookID,
                deviceID: deviceID,
                actionID: head.actionID,
                position: position,
                actionAt: head.actionAt,
                sequence: head.sequence,
                actionKind: actionKind
            )
            _ = try SyncOutboxStore.upsert(
                kind: .saveRecord,
                subjectKind: .progress,
                subjectID: recordName,
                payloadData: try CloudSyncRecordCodec.encodePayload(CloudSyncProgressPayload(action: action)),
                in: context
            )
            try context.save()

            await synchronizeIfEnabled(container: container, auditLibrary: false)
        } catch {
            publishFailure(error, container: container)
        }
    }

    func recordDeletion(
        entityKind: SyncEntityKind,
        entityID: String,
        container: ModelContainer
    ) async {
        let deviceID = try? await SyncDeviceIdentity.shared.identifier()
        let context = ModelContext(container)

        do {
            let pendingCleanups = try stageDeletion(
                entityKind: entityKind,
                entityID: entityID,
                deviceID: deviceID,
                in: context
            )
            for cleanup in Set(pendingCleanups) {
                _ = try StorageCleanupCoordinator.stage(
                    location: cleanup.location,
                    relativePath: cleanup.relativePath,
                    in: context
                )
            }
            try context.save()
        } catch {
            context.rollback()
            publishFailure(error, container: container)
            return
        }

        StorageCleanupCoordinator.drainPendingCleanup(in: context)

        let syncContext = ModelContext(container)
        let runtime = try? SyncRuntimeStore.findOrCreateRuntime(in: syncContext)
        let syncIsEnabled = runtime?.desiredModeRaw == SyncMode.enabled.rawValue
        if syncIsEnabled {
            await synchronizeIfEnabled(container: container, auditLibrary: false)
        }
    }

    @discardableResult
    func stageDeletion(
        entityKind: SyncEntityKind,
        entityID: String,
        deviceID: String?,
        in context: ModelContext
    ) throws -> [PendingFileCleanup] {
        let runtime = try SyncRuntimeStore.findOrCreateRuntime(in: context)
        let deletedAssets: [(UUID, Int64)]
        if entityKind == .book, let bookID = UUID(uuidString: entityID) {
            deletedAssets = try context.fetch(FetchDescriptor<SyncAsset>())
                .filter { $0.bookID == bookID }
                .map { ($0.id, $0.contentRevision) }
        } else {
            deletedAssets = []
        }

        let pendingCleanups = try SyncDeletionCoordinator.discardReplicaState(
            entityKind: entityKind,
            entityID: entityID,
            in: context
        )

        let syncIsEnabled = runtime.desiredModeRaw == SyncMode.enabled.rawValue
        guard syncIsEnabled || runtime.generationID != nil else { return pendingCleanups }

        let resolvedDeviceID = deviceID ?? ""
        let tombstoneID = SyncRecordName.tombstone(kind: entityKind, id: entityID.lowercased())
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        let existing = tombstones.first(where: { $0.id == tombstoneID })
        let nextRevision = (existing?.revision ?? 0) + 1
        let deletedAt = Date()
        if let existing {
            existing.deletedAt = deletedAt
            existing.revision = nextRevision
            existing.deviceID = resolvedDeviceID
        } else {
            context.insert(SyncTombstone(
                id: tombstoneID,
                entityKindRaw: entityKind.rawValue,
                entityID: entityID.lowercased(),
                deletedAt: deletedAt,
                revision: nextRevision,
                deviceID: resolvedDeviceID
            ))
        }
        let payload = CloudSyncTombstonePayload(
            entityKind: entityKind,
            entityID: entityID.lowercased(),
            deletedAt: deletedAt,
            revision: nextRevision,
            deviceID: resolvedDeviceID
        )
        let tombstoneOperation = try SyncOutboxStore.upsert(
            kind: .saveRecord,
            subjectKind: .tombstone,
            subjectID: tombstoneID,
            payloadData: try CloudSyncRecordCodec.encodePayload(payload),
            in: context
        )
        for (assetID, latestRevision) in deletedAssets where latestRevision > 0 {
            for revision in 1...latestRevision {
                _ = try SyncOutboxStore.upsert(
                    kind: .deleteAsset,
                    subjectKind: .asset,
                    subjectID: SyncRecordName.asset(assetID, revision: revision),
                    payloadData: try CloudSyncRecordCodec.encodePayload(
                        CloudSyncAssetDeletionPayload(assetID: assetID, revision: revision)
                    ),
                    dependencyIDs: [tombstoneOperation.id],
                    in: context
                )
            }
        }
        return pendingCleanups
    }

    private func synchronize(container: ModelContainer, auditLibrary: Bool) async {
        guard !isSynchronizing else {
            syncRequestedWhileRunning = true
            auditRequestedWhileRunning = auditRequestedWhileRunning || auditLibrary
            return
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
            if syncRequestedWhileRunning {
                let needsAudit = auditRequestedWhileRunning
                syncRequestedWhileRunning = false
                auditRequestedWhileRunning = false
                Task { [weak self] in await self?.synchronize(container: container, auditLibrary: needsAudit) }
            }
        }

        let previousSuccess = status.lastSuccessfulSyncAt
        status = SyncStatus(mode: .enabled, activity: auditLibrary ? .preparing : .syncing, lastSuccessfulSyncAt: previousSuccess)

        do {
            let context = ModelContext(container)
            let runtime = try SyncRuntimeStore.runtime(in: context)
            guard runtime.desiredModeRaw == SyncMode.enabled.rawValue else {
                status = .disabled
                return
            }
            runtime.lastErrorMessage = nil
            runtime.updatedAt = Date()
            try context.save()

            let activeTransport = try ensureTransport(container: container)
            try await activeTransport.prepareZoneAndFetchChanges()

            let deviceID = try await SyncDeviceIdentity.shared.identifier()
            if auditLibrary {
                let result = await SyncLibraryAuditor.audit(container: container, deviceID: deviceID)
                guard result.failedAssetCount == 0, result.missingAssetCount == 0 else {
                    status = SyncStatus(
                        mode: .enabled,
                        activity: .waiting(reason: "Resolve missing or unreadable local files, then retry."),
                        lastSuccessfulSyncAt: previousSuccess
                    )
                    return
                }
            }

            _ = try SyncOutboxPlanner.plan(container: container, deviceID: deviceID)
            status = SyncStatus(mode: .enabled, activity: .syncing, lastSuccessfulSyncAt: previousSuccess)
            try await activeTransport.sendPendingChanges()
            try await activeTransport.fetchChanges()

            let completionContext = ModelContext(container)
            let completionRuntime = try SyncRuntimeStore.runtime(in: completionContext)
            if let transportError = completionRuntime.lastErrorMessage, !transportError.isEmpty {
                throw SyncControllerError.transport(transportError)
            }
            let remainingOperations = try completionContext.fetch(FetchDescriptor<SyncOutboxOperation>())
                .filter { $0.stateRaw == "queued" || $0.stateRaw == "sending" }
            if !remainingOperations.isEmpty {
                completionRuntime.activeModeRaw = SyncMode.enabled.rawValue
                completionRuntime.updatedAt = Date()
                try completionContext.save()
                let reason = remainingOperations.compactMap(\.lastErrorMessage).first
                    ?? "Some library items are waiting to retry."
                status = SyncStatus(
                    mode: .enabled,
                    activity: .waiting(reason: reason),
                    lastSuccessfulSyncAt: previousSuccess
                )
                return
            }
            let completedAt = Date()
            completionRuntime.activeModeRaw = SyncMode.enabled.rawValue
            completionRuntime.lastSuccessfulSyncAt = completedAt
            completionRuntime.lastErrorMessage = nil
            completionRuntime.updatedAt = completedAt
            try completionContext.save()
            status = SyncStatus(mode: .enabled, activity: .idle, lastSuccessfulSyncAt: completedAt)
        } catch SyncAccountError.confirmationRequired {
            status = SyncStatus(mode: .enabled, activity: .accountConfirmationRequired, lastSuccessfulSyncAt: previousSuccess)
        } catch {
            publishFailure(error, container: container)
        }
    }

    func confirmAccountMerge(container: ModelContainer) async {
        if let transport { await transport.cancel() }
        transport = nil
        do {
            let context = ModelContext(container)
            try SyncAccountCoordinator.confirmMerge(in: context)
            await synchronize(container: container, auditLibrary: true)
        } catch {
            publishFailure(error, container: container)
        }
    }

    func declineAccountMerge(container: ModelContainer) async {
        if let transport { await transport.cancel() }
        transport = nil
        do {
            try SyncAccountCoordinator.declineMerge(in: ModelContext(container))
            status = .disabled
        } catch {
            publishFailure(error, container: container)
        }
    }

    func accountConfirmationBecameRequired(container: ModelContainer) {
        let runtime = try? SyncRuntimeStore.runtime(in: ModelContext(container))
        status = SyncStatus(
            mode: .enabled, activity: .accountConfirmationRequired,
            lastSuccessfulSyncAt: runtime?.lastSuccessfulSyncAt ?? status.lastSuccessfulSyncAt
        )
    }

    private func disable(container: ModelContainer) async {
        if let transport { await transport.cancel() }
        transport = nil
        syncRequestedWhileRunning = false
        auditRequestedWhileRunning = false
        do {
            try setDesiredMode(.disabled, container: container)
        } catch {
            publishFailure(error, container: container)
        }
    }

    private func ensureTransport(container: ModelContainer) throws -> any CloudSyncTransport {
        if let transport { return transport }
        let created = try transportFactory(container)
        transport = created
        return created
    }

    private func publishFailure(_ error: Error, container: ModelContainer) {
        let context = ModelContext(container)
        let message = error.localizedDescription
        if let runtime = try? SyncRuntimeStore.runtime(in: context) {
            runtime.lastErrorMessage = message
            runtime.activeModeRaw = SyncMode.disabled.rawValue
            runtime.updatedAt = Date()
            try? context.save()
        }
        status = SyncStatus(
            mode: .enabled,
            activity: .failed(message: message),
            lastSuccessfulSyncAt: status.lastSuccessfulSyncAt
        )
        AppLogger.sync.error("iCloud sync failed: \(message, privacy: .private)")
    }

    private func status(for runtime: SyncRuntime) -> SyncStatus {
        let desiredMode = SyncMode(rawValue: runtime.desiredModeRaw) ?? .disabled
        let activeMode = SyncMode(rawValue: runtime.activeModeRaw) ?? .disabled

        if let error = runtime.lastErrorMessage, !error.isEmpty {
            return SyncStatus(mode: desiredMode, activity: .failed(message: error), lastSuccessfulSyncAt: runtime.lastSuccessfulSyncAt)
        }
        if desiredMode == .disabled { return .disabled }
        if activeMode == .disabled {
            return SyncStatus(mode: .enabled, activity: .waiting(reason: "iCloud sync is preparing"), lastSuccessfulSyncAt: runtime.lastSuccessfulSyncAt)
        }
        return SyncStatus(mode: .enabled, activity: .idle, lastSuccessfulSyncAt: runtime.lastSuccessfulSyncAt)
    }
}

nonisolated enum SyncControllerError: LocalizedError {
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message): message
        }
    }
}

@MainActor
enum SyncRuntimeStore {
    static func runtime(in context: ModelContext) throws -> SyncRuntime {
        var descriptor = FetchDescriptor<SyncRuntime>(predicate: #Predicate { $0.id == "runtime" })
        descriptor.fetchLimit = 1
        if let runtime = try context.fetch(descriptor).first {
            return runtime
        }

        let runtime = SyncRuntime()
        context.insert(runtime)
        try context.save()
        return runtime
    }

    static func findOrCreateRuntime(in context: ModelContext) throws -> SyncRuntime {
        var descriptor = FetchDescriptor<SyncRuntime>(predicate: #Predicate { $0.id == "runtime" })
        descriptor.fetchLimit = 1
        if let runtime = try context.fetch(descriptor).first {
            return runtime
        }
        let runtime = SyncRuntime()
        context.insert(runtime)
        return runtime
    }
}

@MainActor
enum SyncOutboxStore {
    @discardableResult
    static func upsert(
        kind: SyncOutboxKind,
        subjectKind: SyncEntityKind,
        subjectID: String,
        payloadData: Data? = nil,
        dependencyIDs: [UUID] = [],
        in context: ModelContext
    ) throws -> SyncOutboxOperation {
        let dependencyData = try SyncOutboxDependencyCodec.encode(dependencyIDs)
        let targetSubjectID = subjectID
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>(
            predicate: #Predicate { $0.subjectID == targetSubjectID }
        ))
        if let existing = operations.first(where: {
            $0.kindRaw == kind.rawValue &&
            $0.subjectKindRaw == subjectKind.rawValue &&
            $0.subjectID == subjectID &&
            $0.stateRaw != "sent"
        }) {
            existing.payloadData = payloadData
            existing.dependencyData = dependencyData
            existing.stateRaw = "queued"
            existing.nextRetryAt = nil
            existing.lastErrorMessage = nil
            return existing
        }

        let operation = SyncOutboxOperation(
            kindRaw: kind.rawValue,
            subjectKindRaw: subjectKind.rawValue,
            subjectID: subjectID,
            payloadData: payloadData,
            dependencyData: dependencyData
        )
        context.insert(operation)
        return operation
    }
}
