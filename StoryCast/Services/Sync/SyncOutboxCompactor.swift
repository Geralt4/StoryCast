import Foundation
import SwiftData

@MainActor
enum SyncOutboxCompactor {
    static func compact(in context: ModelContext) throws {
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        let referenced = try Set(operations.flatMap { try SyncOutboxDependencyCodec.decode($0.dependencyData) })
        let retentions = try context.fetch(FetchDescriptor<SyncAssetRetentionState>())

        for retention in retentions {
            var next = retention.prunedThroughRevision + 1
            while operations.contains(where: { operation in
                guard operation.kindRaw == SyncOutboxKind.deleteAsset.rawValue,
                      operation.stateRaw == "sent", let data = operation.payloadData,
                      let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetDeletionPayload.self, from: data)
                else { return false }
                return payload.assetID == retention.assetID && payload.revision == next
            }) { retention.prunedThroughRevision = next; next += 1 }
        }

        var newestSent: [String: SyncOutboxOperation] = [:]
        for operation in operations where operation.stateRaw == "sent" {
            let key = "\(operation.kindRaw)|\(operation.subjectID)"
            if let current = newestSent[key], current.createdAt > operation.createdAt { continue }
            newestSent[key] = operation
        }

        for operation in operations {
            guard !referenced.contains(operation.id) else { continue }
            if operation.stateRaw == "cancelled" {
                context.delete(operation)
                continue
            }
            guard operation.stateRaw == "sent" else { continue }
            if operation.kindRaw == SyncOutboxKind.deleteAsset.rawValue,
               let data = operation.payloadData,
               let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetDeletionPayload.self, from: data),
               retentions.first(where: { $0.assetID == payload.assetID })?.prunedThroughRevision ?? 0 >= payload.revision {
                context.delete(operation)
                for upload in operations where upload.subjectID == operation.subjectID && upload.stateRaw == "sent" {
                    context.delete(upload)
                }
            } else if newestSent["\(operation.kindRaw)|\(operation.subjectID)"]?.id != operation.id {
                context.delete(operation)
            }
        }

        let liveAssetIDs = Set(try context.fetch(FetchDescriptor<SyncAsset>()).map(\.id))
        for retention in retentions where !liveAssetIDs.contains(retention.assetID) {
            let hasOutstandingDelete = operations.contains { operation in
                guard operation.kindRaw == SyncOutboxKind.deleteAsset.rawValue,
                      operation.stateRaw != "sent", let data = operation.payloadData,
                      let payload = try? CloudSyncRecordCodec.decodePayload(CloudSyncAssetDeletionPayload.self, from: data)
                else { return false }
                return payload.assetID == retention.assetID
            }
            if !hasOutstandingDelete { context.delete(retention) }
        }
    }
}
