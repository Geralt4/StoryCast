import Foundation
import os
import SwiftData

enum StorageBootstrapState: Sendable {
    case ready(ModelContainer)
    case failed(StorageInitializationFailure)
    case versionMismatch(StorageVersionError)
    case unrecoverable(Error)

    var allowsLibraryAccess: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct StorageInitializationFailure: Equatable, Sendable {
    let message: String
    let recoverySuggestion: String
    let technicalDetails: String
}

struct StorageUnrecoverableError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum StorageRecoveryOutcome: Equatable, Sendable {
    case restartRequired(backupURL: URL?)
    case failed(StorageUnrecoverableError)
}

private actor StorageRecoveryCoordinator {
    private var inFlight: Task<StorageRecoveryOutcome, Never>?

    func run(
        operation: @Sendable @escaping () async -> StorageRecoveryOutcome
    ) async -> StorageRecoveryOutcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await operation() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }
}

enum AppBootstrap {
    typealias ContainerFactory = (_ schema: Schema, _ migrationPlan: (any SchemaMigrationPlan.Type)?, _ configurations: [ModelConfiguration]) throws -> ModelContainer

    nonisolated static let migrationPlan: (any SchemaMigrationPlan.Type) = StoryCastMigrationPlan.self
    private static let recoveryCoordinator = StorageRecoveryCoordinator()

    nonisolated static func makeStorageBootstrapState(
        containerFactory: ContainerFactory = defaultContainerFactory
    ) -> StorageBootstrapState {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            let container = try containerFactory(schema, migrationPlan, [config])
            return .ready(container)
        } catch {
            let categorizedError = StorageVersionValidator.categorize(error)

            if case .versionMismatchDetected = categorizedError {
                // Log analytics event
                StorageVersionValidator.logVersionMismatchEvent(
                    error: categorizedError,
                    schemaVersion: CurrentSchema.versionString
                )
                return .versionMismatch(categorizedError)
            }

            // For migration or unknown errors, proceed with generic failure
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
        let plans: [(any SchemaMigrationPlan.Type)?] = [
            migrationPlan,
            StoryCastMarkerV3MigrationPlan.self,
            StoryCastLegacyV4MigrationPlan.self
        ]
        var primaryError: Error?
        for plan in plans {
            do {
                return try ModelContainer(
                    for: schema,
                    migrationPlan: plan,
                    configurations: configurations
                )
            } catch {
                if primaryError == nil { primaryError = error }
            }
        }
        throw primaryError ?? StorageUnrecoverableError(message: "No compatible migration plan was available")
    }

    nonisolated static func makeRecoveryContainer() -> ModelContainer? {
        let schema = Schema(versionedSchema: SchemaV6.self)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                // Recovery containers don't need migration - they start fresh in memory.
                // Use a dedicated in-memory config so we never touch the persistent store
                // in a recovery path, regardless of the sync toggle.
                let inMemoryConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
                return try ModelContainer(for: schema, configurations: [inMemoryConfig])
            } catch {
                lastError = error
                AppLogger.app.error("Recovery container attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }

        AppLogger.app.critical("All recovery container attempts failed: \(lastError?.localizedDescription ?? "unknown")")
        return nil
    }

    // MARK: - Recovery Operations

    /// Backs up and recreates the database. The new store becomes active only
    /// after relaunch so existing model contexts never point at a deleted store.
    nonisolated static func startFresh(
        operation: @Sendable @escaping () async -> StorageRecoveryOutcome = performFreshStart
    ) async -> StorageRecoveryOutcome {
        await recoveryCoordinator.run(operation: operation)
    }

    /// Shared implementation for recovery operations
    /// Backs up old database, deletes it, creates new persistent container
    private nonisolated static func performFreshStart() async -> StorageRecoveryOutcome {
        // 1. Backup existing database AND cover art BEFORE any deletion
        let backupURL: URL?
        if StorageBackupManager.databaseURL != nil {
            guard let createdBackupURL = StorageBackupManager.backupDatabase() else {
                AppLogger.app.critical("Database backup failed — aborting fresh start to prevent data loss")
                return .failed(StorageUnrecoverableError(
                    message: "Unable to backup existing database before recovery"
                ))
            }
            backupURL = createdBackupURL
            AppLogger.app.info("Created backup before recovery: \(createdBackupURL.path)")
        } else {
            backupURL = nil
        }

        // Also backup cover art (small files, critical for UX)
        _ = StorageBackupManager.backupCoverArt()

        // 2. Delete all database files only after successful backup
        let deletedSuccessfully = StorageBackupManager.deleteDatabaseFiles()
        if !deletedSuccessfully {
            AppLogger.app.critical("Some database files could not be deleted — aborting fresh start")
            return .failed(StorageUnrecoverableError(message: "Unable to remove the old database safely"))
        }

        // 3. Create NEW persistent container (NOT in-memory!)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            _ = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [config])
            AppLogger.app.info("Successfully created fresh persistent database")

            // Restore cover art to the new database
            _ = StorageBackupManager.restoreCoverArt()

            return .restartRequired(backupURL: backupURL)
        } catch {
            AppLogger.app.critical("Failed to create fresh database: \(error.localizedDescription)")
            return .failed(StorageUnrecoverableError(message: "Unable to create fresh database"))
        }
    }

}
