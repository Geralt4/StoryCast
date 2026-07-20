import Foundation
import SwiftData

nonisolated enum SyncAccountError: LocalizedError {
    case confirmationRequired

    var errorDescription: String? {
        "Confirm merging this device's imported library with the new iCloud account before syncing."
    }
}

@MainActor
enum SyncAccountCoordinator {
    static func binding(in context: ModelContext) throws -> SyncAccountBinding {
        if let binding = try context.fetch(FetchDescriptor<SyncAccountBinding>()).first { return binding }
        let runtime = try SyncRuntimeStore.runtime(in: context)
        let binding = SyncAccountBinding(
            confirmedAccountIdentifier: runtime.accountIdentifier,
            stateRaw: runtime.accountIdentifier == nil ? "unbound" : "confirmed"
        )
        context.insert(binding)
        return binding
    }

    static func validate(accountIdentifier: String, in context: ModelContext) throws {
        let binding = try binding(in: context)
        if binding.stateRaw == "confirmationRequired" {
            throw SyncAccountError.confirmationRequired
        }
        guard let confirmed = binding.confirmedAccountIdentifier else {
            binding.confirmedAccountIdentifier = accountIdentifier
            binding.stateRaw = "confirmed"
            binding.updatedAt = Date()
            let runtime = try SyncRuntimeStore.runtime(in: context)
            runtime.accountIdentifier = accountIdentifier
            try context.save()
            return
        }
        guard confirmed == accountIdentifier else {
            binding.pendingAccountIdentifier = accountIdentifier
            binding.stateRaw = "confirmationRequired"
            binding.updatedAt = Date()
            let runtime = try SyncRuntimeStore.runtime(in: context)
            runtime.activeModeRaw = SyncMode.disabled.rawValue
            runtime.lastErrorMessage = nil
            try context.save()
            throw SyncAccountError.confirmationRequired
        }
    }

    static func confirmMerge(in context: ModelContext) throws {
        let binding = try binding(in: context)
        guard let pending = binding.pendingAccountIdentifier else { return }

        let states = try context.fetch(FetchDescriptor<SyncEntityState>())
        let existingMarkers = try context.fetch(FetchDescriptor<SyncReplicaUploadMarker>())
        let markerIDs = Set(existingMarkers.map(\.id))
        for state in states {
            state.recordSystemFields = nil
            if !markerIDs.contains(state.id) {
                context.insert(SyncReplicaUploadMarker(
                    id: state.id, recordName: state.recordName, reasonRaw: "accountMerge"
                ))
            }
        }
        for operation in try context.fetch(FetchDescriptor<SyncOutboxOperation>()) { context.delete(operation) }
        for inbox in try context.fetch(FetchDescriptor<SyncInboxRecord>()) { context.delete(inbox) }
        for cloudState in try context.fetch(FetchDescriptor<SyncCloudRecordState>()) { context.delete(cloudState) }
        for retention in try context.fetch(FetchDescriptor<SyncAssetRetentionState>()) { context.delete(retention) }
        for tombstone in try context.fetch(FetchDescriptor<SyncTombstone>()) { context.delete(tombstone) }
        for asset in try context.fetch(FetchDescriptor<SyncAsset>()) {
            asset.cloudStateRaw = SyncAssetCloudState.notScheduled.rawValue
            asset.cloudRelativePath = nil
            asset.retryAfter = nil
            asset.lastErrorMessage = nil
        }

        let runtime = try SyncRuntimeStore.runtime(in: context)
        runtime.accountIdentifier = pending
        runtime.generationID = nil
        runtime.engineStateData = nil
        runtime.lastSuccessfulSyncAt = nil
        runtime.lastErrorMessage = nil
        runtime.activeModeRaw = SyncMode.disabled.rawValue
        runtime.updatedAt = Date()
        binding.confirmedAccountIdentifier = pending
        binding.pendingAccountIdentifier = nil
        binding.boundGenerationID = nil
        binding.stateRaw = "confirmed"
        binding.updatedAt = Date()
        try context.save()
    }

    static func declineMerge(in context: ModelContext) throws {
        let binding = try binding(in: context)
        binding.pendingAccountIdentifier = nil
        binding.stateRaw = "confirmed"
        binding.updatedAt = Date()
        let runtime = try SyncRuntimeStore.runtime(in: context)
        runtime.desiredModeRaw = SyncMode.disabled.rawValue
        runtime.activeModeRaw = SyncMode.disabled.rawValue
        runtime.lastErrorMessage = nil
        runtime.updatedAt = Date()
        UserDefaults.standard.set(false, forKey: CloudSyncDefaults.iCloudSyncEnabledKey)
        try context.save()
    }
}
