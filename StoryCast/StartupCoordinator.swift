import Combine
import Foundation
import os
import SwiftData
import SwiftUI

@MainActor
final class StartupCoordinator: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let legacyDeduplicationKey = "hasCompletedLegacyLibraryDeduplication"
    private let normalizedURLMigrationKey = "hasCompletedNormalizedURLMigration"
    private var hasRequestedStartup = false
    private var hasScheduledMaintenance = false
    private var startupTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    func startIfNeeded(container: ModelContainer) async {
        guard !hasRequestedStartup else { return }
        hasRequestedStartup = true
        await runStartup(container: container)
    }

    func retry(container: ModelContainer) async {
        loadError = nil
        await runStartup(container: container)
    }

    private func runStartup(container: ModelContainer) async {
        guard startupTask == nil else { return }

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isLoading = true
            defer {
                isLoading = false
                startupTask = nil
            }

            do {
                prewarmCoreServices()
                try LibraryMaintenanceService.ensureUnfiledFolderExists(container: container)
                try await prewarmAppResources(container: container)
                scheduleMaintenanceIfNeeded(container: container)
            } catch {
                loadError = error.localizedDescription
                hasRequestedStartup = false
            }
        }

        await startupTask?.value
    }

    private func scheduleMaintenanceIfNeeded(container: ModelContainer) {
        guard !hasScheduledMaintenance else { return }
        hasScheduledMaintenance = true

        let legacyDeduplicationKey = legacyDeduplicationKey
        let normalizedURLMigrationKey = normalizedURLMigrationKey
        maintenanceTask = Task(priority: .utility) { [weak self] in
            await PlaybackSessionManager.shared.recoverPendingProgressIfNeeded(container: container)
            await LibraryMaintenanceService.repairLibraryIntegrity(container: container)
            await LibraryMaintenanceService.adoptManagedLibraryFiles(container: container)

            if !UserDefaults.standard.bool(forKey: legacyDeduplicationKey) {
                let result = await LibraryMaintenanceService.deduplicateExistingBooks(container: container)
                if result.completed {
                    UserDefaults.standard.set(true, forKey: legacyDeduplicationKey)
                }
            }

            if !UserDefaults.standard.bool(forKey: normalizedURLMigrationKey) {
                await Self.migrateNormalizedURL(container: container)
                UserDefaults.standard.set(true, forKey: normalizedURLMigrationKey)
            }

            await LibraryMaintenanceService.syncRemoteLibraries(container: container)

            await MainActor.run {
                self?.maintenanceTask = nil
            }
        }
    }

    private func prewarmCoreServices() {
        _ = SleepTimerService.shared
        _ = PlaybackSettings.load()
        _ = SleepTimerSettings.load()
    }

    private func prewarmAppResources(container: ModelContainer) async throws {
        async let swiftDataTask: Void = Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)

            var folderFetch = FetchDescriptor<Folder>()
            folderFetch.fetchLimit = 1
            _ = try? backgroundContext.fetch(folderFetch)

            var bookFetch = FetchDescriptor<Book>()
            bookFetch.fetchLimit = 1
            _ = try? backgroundContext.fetch(bookFetch)
        }.value

        async let storageTask: Void = Task.detached(priority: .utility) {
            try await StorageManager.shared.setupStoryCastLibraryDirectory()
            try await StorageManager.shared.setupCoverArtDirectory()
            try await StorageManager.shared.setupRemoteAudioCacheDirectory()
            try await StorageManager.shared.setupRemoteCoverArtDirectory()
            try await StorageManager.shared.migrateFileProtectionIfNeeded()
            try await StorageManager.shared.migrateRemoteAssetsIfNeeded(container: container)
        }.value

        _ = try await (swiftDataTask, storageTask)
    }

    private static func migrateNormalizedURL(container: ModelContainer) async {
        let context = ModelContext(container)
        do {
            let servers = try context.fetch(FetchDescriptor<ABSServer>())
            for server in servers {
                if server.normalizedURL.isEmpty {
                    server.normalizedURL = ABSServer.computeNormalizedURL(from: server.url)
                }
            }
            try context.save()
        } catch {
            AppLogger.app.error("Failed to migrate normalizedURL for existing servers: \(error.localizedDescription)")
        }
    }
}
