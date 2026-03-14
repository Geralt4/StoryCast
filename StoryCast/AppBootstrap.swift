import Foundation
import os
import SwiftData

enum StorageBootstrapState: Sendable {
    case ready(ModelContainer)
    case failed(StorageInitializationFailure)
    case unrecoverable(Error)
}

struct StorageInitializationFailure: Equatable, Sendable {
    let message: String
    let recoverySuggestion: String
    let technicalDetails: String
}

struct StorageUnrecoverableError: Error, Sendable {
    let message: String
}

enum AppBootstrap {
    typealias ContainerFactory = (_ schema: Schema, _ migrationPlan: (any SchemaMigrationPlan.Type)?, _ configurations: [ModelConfiguration]) throws -> ModelContainer

    nonisolated static let migrationPlan: (any SchemaMigrationPlan.Type) = StoryCastMigrationPlan.self

    nonisolated static func makeStorageBootstrapState(
        containerFactory: ContainerFactory = defaultContainerFactory
    ) -> StorageBootstrapState {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try containerFactory(schema, migrationPlan, [config])
            return .ready(container)
        } catch {
            AppLogger.app.critical("Failed to open persistent model container: \(error.localizedDescription)")
            return .failed(
                StorageInitializationFailure(
                    message: "StoryCast couldn't open your library safely.",
                    recoverySuggestion: "Restart the app before importing or downloading anything. If the problem persists, protect your existing app data before reinstalling or restoring from backup.",
                    technicalDetails: error.localizedDescription
                )
            )
        }
    }

    nonisolated private static func defaultContainerFactory(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configurations: [ModelConfiguration]
    ) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configurations)
    }

    nonisolated static func makeRecoveryContainer() -> ModelContainer? {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [config])
            } catch {
                lastError = error
                AppLogger.app.error("Recovery container attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        
        AppLogger.app.critical("All recovery container attempts failed: \(lastError?.localizedDescription ?? "unknown")")
        return nil
    }
}
