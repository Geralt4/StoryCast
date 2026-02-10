import SwiftUI
import SwiftData
import os

@main
struct StoryCastApp: App {
    @AppStorage("isUsingInMemoryStorage") private var isUsingInMemoryStorage = false
    let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema(versionedSchema: SchemaV1.self)
        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            sharedModelContainer = try ModelContainer(for: schema, configurations: [config])
            isUsingInMemoryStorage = false
        } catch {
            AppLogger.app.critical("Could not create ModelContainer: \(error.localizedDescription, privacy: .private)")
            do {
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                AppLogger.app.warning("Using in-memory container as fallback")
                sharedModelContainer = try ModelContainer(for: schema, configurations: [config])
                isUsingInMemoryStorage = true
            } catch {
                fatalError("Could not create even in-memory ModelContainer: \(error)")
            }
        }
    }

    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.automatic.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var appearanceColorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearanceColorScheme)
                .environmentObject(ImportService.shared)
                .onOpenURL { url in
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

    private func saveCurrentPlaybackPosition() {
        let player = AudioPlayerService.shared
        guard let currentURL = player.currentURL else { return }
        let currentTime = player.currentTime
        guard currentTime.isFinite, currentTime >= 0 else { return }
        let fileName = currentURL.lastPathComponent

        // Note: App struct cannot use @Environment(\.modelContext), so a separate
        // ModelContext is required here. This is acceptable because we only write
        // one property (lastPlaybackPosition) and save immediately.
        let context = ModelContext(sharedModelContainer)
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.localFileName == fileName })
        descriptor.fetchLimit = 1
        do {
            guard let book = try context.fetch(descriptor).first else { return }
            book.lastPlaybackPosition = currentTime
            try context.save()
        } catch {
            AppLogger.app.error("Failed to save playback position: \(error.localizedDescription, privacy: .private)")
        }
    }

}
