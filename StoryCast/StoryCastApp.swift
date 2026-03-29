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
            } else if let container = Self.lastResortContainer {
                storageBootstrapState = .unrecoverable(StorageUnrecoverableError(message: failure.message))
                sharedModelContainer = container
            } else {
                storageBootstrapState = .unrecoverable(StorageUnrecoverableError(message: "Unable to create recovery container"))
                sharedModelContainer = Self.fatalFallbackContainer
            }
        case .versionMismatch(let error):
            // First try to create a persistent container from backup (preserves user data)
            if let persistentContainer = AppBootstrap.makePersistentRecoveryContainer() {
                storageBootstrapState = .versionMismatch(error)
                sharedModelContainer = persistentContainer
            } else if let recoveryContainer = AppBootstrap.makeRecoveryContainer() {
                // Fall back to in-memory container if persistent recovery fails
                storageBootstrapState = .versionMismatch(error)
                sharedModelContainer = recoveryContainer
            } else if let container = Self.lastResortContainer {
                storageBootstrapState = .unrecoverable(error)
                sharedModelContainer = container
            } else {
                storageBootstrapState = .unrecoverable(StorageUnrecoverableError(message: "Unable to create recovery container"))
                sharedModelContainer = Self.fatalFallbackContainer
            }
        case .unrecoverable(let error):
            storageBootstrapState = .unrecoverable(error)
            let schema = Schema(versionedSchema: SchemaV3.self)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let container = try? ModelContainer(for: schema, configurations: [config]) {
                sharedModelContainer = container
            } else if let container = Self.lastResortContainer {
                sharedModelContainer = container
            } else {
                sharedModelContainer = Self.fatalFallbackContainer
            }
        }
    }

    private nonisolated static var lastResortContainer: ModelContainer? {
        let schema = Schema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        // Strategy 1: Try empty Schema
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        
        // Strategy 2: Retry once (handles transient memory pressure)
        AppLogger.app.warning("First attempt to create lastResortContainer failed, retrying...")
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        
        // Strategy 3: Try SchemaV3 (handles case where empty Schema fails but main schema works)
        let minimalSchema = Schema(versionedSchema: SchemaV3.self)
        let minimalConfig = ModelConfiguration(schema: minimalSchema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: minimalSchema, configurations: [minimalConfig]) {
            return container
        }
        
        // Strategy 4: Retry SchemaV3 once
        AppLogger.app.warning("First SchemaV3 attempt failed, retrying...")
        if let container = try? ModelContainer(for: minimalSchema, configurations: [minimalConfig]) {
            return container
        }
        
        AppLogger.app.critical("All lastResortContainer attempts failed — this is a catastrophic failure")
        return nil
    }
    
    private static let fatalFallbackContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

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
                .onReceive(NotificationCenter.default.publisher(for: .init("StoryCast.SavePlaybackPosition"))) { _ in
                    saveCurrentPlaybackPosition()
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
