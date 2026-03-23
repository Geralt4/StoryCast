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
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        
        AppLogger.app.critical("All recovery container attempts failed: \(lastError?.localizedDescription ?? "unknown")")
        return nil
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
        // 1. Backup existing database BEFORE any deletion
        let backupURL = StorageBackupManager.backupDatabase()
        if let backupURL = backupURL {
            AppLogger.app.info("Created backup before recovery: \(backupURL.path)")
        }
        
        // 2. Delete all database files
        StorageBackupManager.deleteDatabaseFiles()
        
        // 3. Create NEW persistent container (NOT in-memory!)
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            let container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [config])
            AppLogger.app.info("Successfully created fresh persistent database")
            return .ready(container)
        } catch {
            AppLogger.app.critical("Failed to create fresh database: \(error.localizedDescription)")
            return .unrecoverable(
                StorageUnrecoverableError(message: "Unable to create fresh database")
            )
        }
    }
}
