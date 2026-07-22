import SwiftUI
import SwiftData
import os

@main
struct StoryCastApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

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
            if let recoveryContainer = AppBootstrap.makeRecoveryContainer() {
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
            let schema = Schema(versionedSchema: SchemaV6.self)
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
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
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        // Strategy 1: Try the current schema
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }

        // Strategy 2: Retry once (handles transient memory pressure)
        AppLogger.app.warning("First attempt to create lastResortContainer failed, retrying...")
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }

        AppLogger.app.critical("All lastResortContainer attempts failed — this is a catastrophic failure")
        return nil
    }
    
    private static let fatalFallbackContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            AppLogger.app.critical("fatalFallbackContainer creation failed: \(error)")
            let unrecoverable = StorageUnrecoverableError(message: "Unable to create a minimal in-memory container. Your device may be out of memory.")
            fatalError("StoryCast could not start: \(unrecoverable.message)")
        }
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
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background || newPhase == .inactive {
                        saveCurrentPlaybackPosition()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .savePlaybackPosition)) { _ in
                    saveCurrentPlaybackPosition()
                }

        }
        .modelContainer(sharedModelContainer)
    }

    @MainActor
    private func saveCurrentPlaybackPosition() {
        guard storageBootstrapState.allowsLibraryAccess else { return }

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
                // O(n) fetch-and-filter is acceptable here because this runs
                // infrequently (on background/inactive scene phase) and the
                // predicate would need to compare optional properties which
                // SwiftData's #Predicate has limited support for.
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
            // Standardize both URLs so path differences (trailing slashes,
            // symlink resolution) don't cause a false mismatch.
            let isRemoteCache = currentURL.deletingLastPathComponent().standardizedFileURL
                == StorageManager.shared.remoteAudioCacheDirectoryURL.standardizedFileURL
            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { book in
                isRemoteCache ? book.localCachePath == fileName : book.localFileName == fileName
            })
            descriptor.fetchLimit = 1

            guard let book = try context.fetch(descriptor).first else { return }
            book.lastPlaybackPosition = currentTime
            try context.save()

            Task {
                await SyncController.shared.recordProgress(
                    bookID: book.id,
                    position: currentTime,
                    actionKind: "background",
                    container: sharedModelContainer
                )
            }
            
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
            // Roll back the failed context before doing any further fetches:
            // the context may hold uncommitted mutations from the previous
            // (failed) save that would otherwise influence the next fetch.
            context.rollback()
            // For local books, backup to UserDefaults
            let fileName = currentURL.lastPathComponent
            // Standardize both URLs so path differences (trailing slashes,
            // symlink resolution) don't cause a false mismatch.
            let isRemoteCache = currentURL.deletingLastPathComponent().standardizedFileURL
                == StorageManager.shared.remoteAudioCacheDirectoryURL.standardizedFileURL
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
