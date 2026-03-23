import SwiftUI
import SwiftData
import os

@main
struct StoryCastApp: App {
    let storageBootstrapState: StorageBootstrapState
    let sharedModelContainer: ModelContainer

    init() {
        let bootstrapState = AppBootstrap.makeStorageBootstrapState()

        switch bootstrapState {
        case .ready(let container):
            storageBootstrapState = .ready(container)
            sharedModelContainer = container
        case .failed(let failure):
            if let recoveryContainer = AppBootstrap.makeRecoveryContainer() {
                storageBootstrapState = .failed(failure)
                sharedModelContainer = recoveryContainer
            } else {
                let schema = Schema(versionedSchema: SchemaV3.self)
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                var minimalContainer: ModelContainer?
                for attempt in 0..<3 {
                    do {
                        let container = try ModelContainer(for: schema, configurations: [config])
                        minimalContainer = container
                        break
                    } catch {
                        AppLogger.app.error("ModelContainer creation attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .private)")
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if let container = minimalContainer {
                    sharedModelContainer = container
                } else {
                    AppLogger.app.critical("Failed to create any ModelContainer after 3 attempts - using SchemaV2 fallback")
                    do {
                        let fallback = try ModelContainer(for: schema, configurations: [config])
                        sharedModelContainer = fallback
                    } catch {
                        AppLogger.app.critical("SchemaV2 fallback also failed: \(error.localizedDescription, privacy: .private)")
                        let emptySchema = Schema()
                        let emptyConfig = ModelConfiguration(schema: emptySchema, isStoredInMemoryOnly: true)
                        do {
                            sharedModelContainer = try ModelContainer(for: emptySchema, configurations: [emptyConfig])
                        } catch {
                            AppLogger.app.critical("Empty schema fallback also failed: \(error.localizedDescription, privacy: .private)")
                            sharedModelContainer = Self.lastResortContainer
                        }
                    }
                }
                storageBootstrapState = .unrecoverable(StorageUnrecoverableError(message: failure.message))
            }
        case .versionMismatch(let error):
            // Try to create a recovery container for version mismatch
            if let recoveryContainer = AppBootstrap.makeRecoveryContainer() {
                storageBootstrapState = .versionMismatch(error)
                sharedModelContainer = recoveryContainer
            } else {
                // Fallback to unrecoverable state
                storageBootstrapState = .unrecoverable(error)
                sharedModelContainer = Self.lastResortContainer
            }
        case .unrecoverable(let error):
            storageBootstrapState = .unrecoverable(error)
            let schema = Schema(versionedSchema: SchemaV3.self)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                sharedModelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                AppLogger.app.critical("ModelContainer creation failed in unrecoverable path: \(error.localizedDescription, privacy: .private)")
                sharedModelContainer = Self.lastResortContainer
            }
        }
    }

    private nonisolated static var lastResortContainer: ModelContainer {
        let schema = Schema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            AppLogger.app.critical("lastResortContainer creation failed: \(error.localizedDescription, privacy: .private)")
            fatalError("Unable to create any ModelContainer - this should never happen")
        }
    }

    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.automatic.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var appearanceColorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView(storageBootstrapState: storageBootstrapState)
                .preferredColorScheme(appearanceColorScheme)
                .environmentObject(ImportService.shared)
                .onOpenURL { url in
                    guard case .ready = storageBootstrapState else {
                        AppLogger.app.error("Blocked file import while storage recovery mode is active")
                        return
                    }

                    Task {
                        do {
                            try await ImportService.shared.importFile(url: url, container: sharedModelContainer)
                        } catch {
                            AppLogger.app.error("Failed to import file from URL: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background || newPhase == .inactive {
                        saveCurrentPlaybackPosition()
                    }
                }

        }
        .modelContainer(sharedModelContainer)
    }

    @MainActor
    private func saveCurrentPlaybackPosition() {
        guard case .ready = storageBootstrapState else { return }

        let player = AudioPlayerService.shared
        guard let currentURL = player.currentURL else { return }
        let currentTime = player.currentTime
        guard currentTime.isFinite, currentTime >= 0 else { return }

        // Note: App struct cannot use @Environment(\.modelContext), so a separate
        // ModelContext is required here. This is acceptable because we only write
        // one property (lastPlaybackPosition) and save immediately.
        let context = ModelContext(sharedModelContainer)

        do {
            if let remoteItemId = PlaybackSessionManager.shared.activeRemoteItemId {
                let activeServerID = PlaybackSessionManager.shared.activeRemoteServerID
                let books = try context.fetch(FetchDescriptor<Book>())
                if let book = books.first(where: { book in
                    book.remoteItemId == remoteItemId && (activeServerID == nil || book.serverId == activeServerID)
                }) {
                    book.lastPlaybackPosition = currentTime
                    try context.save()
                    return
                }
            }

            let fileName = currentURL.lastPathComponent
            let isRemoteCache = currentURL.deletingLastPathComponent() == StorageManager.shared.remoteAudioCacheDirectoryURL
            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { book in
                isRemoteCache ? book.localCachePath == fileName : book.localFileName == fileName
            })
            descriptor.fetchLimit = 1

            guard let book = try context.fetch(descriptor).first else { return }
            book.lastPlaybackPosition = currentTime
            try context.save()
            
            // Clear any existing UserDefaults backup after successful save
            let backupKey = "localBookPosition_\(book.id.uuidString)"
            UserDefaults.standard.removeObject(forKey: backupKey)
        } catch {
            AppLogger.app.error("Failed to save playback position: \(error.localizedDescription, privacy: .private)")
            // Backup to UserDefaults as fallback for local books
            if PlaybackSessionManager.shared.activeRemoteItemId != nil {
                // Remote books use ProgressBackupStore, skip here
                return
            }
            
            // For local books, backup to UserDefaults
            let fileName = currentURL.lastPathComponent
            let isRemoteCache = currentURL.deletingLastPathComponent() == StorageManager.shared.remoteAudioCacheDirectoryURL
            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { book in
                isRemoteCache ? book.localCachePath == fileName : book.localFileName == fileName
            })
            descriptor.fetchLimit = 1
            
            if let book = try? context.fetch(descriptor).first {
                let backupKey = "localBookPosition_\(book.id.uuidString)"
                let backup: [String: Any] = [
                    "currentTime": currentTime,
                    "timestamp": Date().timeIntervalSince1970
                ]
                UserDefaults.standard.set(backup, forKey: backupKey)
                AppLogger.app.debug("Backed up playback position to UserDefaults: \(currentTime)s")
            }
        }
    }

}
