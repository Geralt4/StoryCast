import Foundation
import os
import SwiftData

enum StorageBootstrapState: Sendable {
    case ready(ModelContainer)
    case failed(StorageInitializationFailure)
    case versionMismatch(StorageVersionError)
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
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try containerFactory(schema, migrationPlan, [config])
            return .ready(container)
        } catch {
            // Check for version mismatch before treating as generic failure
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
        try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configurations)
    }

    nonisolated static func makeRecoveryContainer() -> ModelContainer? {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                // Recovery containers don't need migration - they start fresh in memory
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                lastError = error
                AppLogger.app.error("Recovery container attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        
        AppLogger.app.critical("All recovery container attempts failed: \(lastError?.localizedDescription ?? "unknown")")
        return nil
    }

    /// Creates a persistent recovery container by restoring from the latest backup
    /// This preserves user data while allowing the app to function
    nonisolated static func makePersistentRecoveryContainer() -> ModelContainer? {
        let backups = StorageBackupManager.listBackups()
        guard let latestBackupURL = backups.first else {
            AppLogger.app.info("No backup found for persistent recovery")
            return nil
        }

        // Try to open the backup directly as a ModelContainer
        // This works if the backup has a compatible schema (no migration needed since we open existing data)
        let schema = Schema(versionedSchema: SchemaV3.self)
        let backupConfig = ModelConfiguration(schema: schema, url: latestBackupURL)

        do {
            let container = try ModelContainer(for: schema, configurations: [backupConfig])
            AppLogger.app.info("Successfully created persistent recovery container from backup at \(latestBackupURL.path, privacy: .private)")
            return container
        } catch {
            AppLogger.app.warning("Could not open backup directly (schema may be incompatible): \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Recovery Operations
    
    /// Attempts recovery by backing up and recreating the database
    /// Returns the new container, or nil if recovery failed
    nonisolated static func attemptRecovery() async -> ModelContainer? {
        let state = await performFreshStart()

        switch state {
        case .ready(let container):
            return container
        default:
            return nil
        }
    }

    /// Starts fresh: backs up, deletes old database, creates new one
    /// Returns the new bootstrap state
    nonisolated static func startFresh() async -> StorageBootstrapState {
        await performFreshStart()
    }

    /// Shared implementation for recovery operations
    /// Backs up old database, deletes it, creates new persistent container
    private nonisolated static func performFreshStart() async -> StorageBootstrapState {
        // 1. Backup existing database AND cover art BEFORE any deletion
        guard let backupURL = StorageBackupManager.backupDatabase() else {
            AppLogger.app.critical("Database backup failed — aborting fresh start to prevent data loss")
            return .unrecoverable(
                StorageUnrecoverableError(message: "Unable to backup existing database before recovery")
            )
        }
        AppLogger.app.info("Created backup before recovery: \(backupURL.path)")

        // Also backup cover art (small files, critical for UX)
        _ = StorageBackupManager.backupCoverArt()
        
        // 2. Delete all database files only after successful backup
        let deletedSuccessfully = StorageBackupManager.deleteDatabaseFiles()
        if !deletedSuccessfully {
            AppLogger.app.warning("Some database files could not be deleted — proceeding with fresh start anyway")
        }

        // 3. Create NEW persistent container (NOT in-memory!)
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [config])
            AppLogger.app.info("Successfully created fresh persistent database")
            
            // Restore cover art to the new database
            _ = StorageBackupManager.restoreCoverArt()
            
            return .ready(container)
        } catch {
            AppLogger.app.critical("Failed to create fresh database: \(error.localizedDescription)")
            return .unrecoverable(
                StorageUnrecoverableError(message: "Unable to create fresh database")
            )
        }
    }
}
