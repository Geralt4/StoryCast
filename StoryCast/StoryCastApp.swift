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
            DownloadManager.shared.configure(container: container)
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
        PlaybackPositionSaver.saveCurrentPosition(container: sharedModelContainer)
    }

}
