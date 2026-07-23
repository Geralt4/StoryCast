import Foundation
import SwiftData

nonisolated enum SyncOutboxDependencyCodec {
    static func encode(_ identifiers: [UUID]) throws -> Data? {
        guard !identifiers.isEmpty else { return nil }
        return try JSONEncoder().encode(identifiers)
    }

    static func decode(_ data: Data?) throws -> [UUID] {
        guard let data, !data.isEmpty else { return [] }
        return try JSONDecoder().decode([UUID].self, from: data)
    }
}

@MainActor
enum SyncOutboxProcessor {
    /// A process may be terminated after a batch is handed to CloudKit but
    /// before its acknowledgement is persisted. CKSyncEngine's serialized
    /// pending state makes resending safe, so recover those rows as queued.
    static func recoverInterruptedOperations(in context: ModelContext) {
        guard let operations = try? context.fetch(FetchDescriptor<SyncOutboxOperation>()) else { return }
        for operation in operations where operation.stateRaw == "sending" {
            operation.stateRaw = "queued"
        }
    }

    /// Returns queued operations whose dependencies were acknowledged. An
    /// operation never becomes sendable just because its dependency vanished.
    static func readyOperations(in context: ModelContext, at date: Date = Date()) throws -> [SyncOutboxOperation] {
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        let operationsByID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })

        return operations
            .filter { operation in
                guard operation.stateRaw == "queued" else { return false }
                guard operation.nextRetryAt.map({ $0 <= date }) ?? true else { return false }
                guard let dependencyIDs = try? SyncOutboxDependencyCodec.decode(operation.dependencyData) else { return false }
                return dependencyIDs.allSatisfy { operationsByID[$0]?.stateRaw == "sent" }
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    static func markSending(_ operation: SyncOutboxOperation) {
        operation.stateRaw = "sending"
        operation.lastErrorMessage = nil
    }

    static func markSent(_ operation: SyncOutboxOperation) {
        operation.stateRaw = "sent"
        operation.nextRetryAt = nil
        operation.lastErrorMessage = nil
    }

    static func markRetry(
        _ operation: SyncOutboxOperation,
        message: String,
        retryAfter: Date?
    ) {
        operation.stateRaw = "queued"
        operation.attemptCount += 1
        let cappedExponent = min(operation.attemptCount - 1, 8)
        let fallbackDelay = min(300, pow(2, Double(cappedExponent)))
        operation.nextRetryAt = retryAfter ?? Date().addingTimeInterval(fallbackDelay)
        operation.lastErrorMessage = message
    }

    static func resetRetries(in context: ModelContext) throws {
        let operations = try context.fetch(FetchDescriptor<SyncOutboxOperation>())
        for operation in operations where operation.stateRaw == "queued" {
            operation.nextRetryAt = nil
            operation.lastErrorMessage = nil
        }
    }
}
