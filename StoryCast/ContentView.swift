import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    let storageBootstrapState: StorageBootstrapState

    @ObservedObject private var startupCoordinator = StartupCoordinator.shared

    var body: some View {
        Group {
            switch storageBootstrapState {
            case .ready:
                contentBody
            case .failed(let failure):
                StorageRecoveryView(failure: failure)
            case .versionMismatch(let error):
                StorageVersionMismatchView(error: error)
            case .unrecoverable(let error):
                FatalErrorView(error: error, onReset: {
                    Task {
                        await StorageManager.shared.resetAllData(container: modelContext.container)
                    }
                })
            }
        }
        .task {
            guard storageBootstrapState.allowsLibraryAccess else { return }
            await startupCoordinator.startIfNeeded(container: modelContext.container)
        }
        .onOpenURL { url in
            guard storageBootstrapState.allowsLibraryAccess else {
                AppLogger.app.error("Blocked file import while storage recovery mode is active")
                return
            }

            Task {
                await startupCoordinator.startIfNeeded(container: modelContext.container)
                guard startupCoordinator.loadError == nil else {
                    AppLogger.app.error("Blocked file import because startup did not complete")
                    return
                }

                do {
                    try await ImportService.shared.importFile(url: url, container: modelContext.container)
                    await SyncController.shared.synchronizeIfEnabled(
                        container: modelContext.container,
                        auditLibrary: true
                    )
                } catch {
                    AppLogger.app.error("Failed to import file from URL: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, storageBootstrapState.allowsLibraryAccess else { return }
            Task {
                await startupCoordinator.startIfNeeded(container: modelContext.container)
                guard startupCoordinator.loadError == nil else { return }
                await SyncController.shared.synchronizeIfEnabled(container: modelContext.container)
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let error = startupCoordinator.loadError {
            ContentUnavailableView {
                Label("Error Loading App", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task {
                        await startupCoordinator.retry(container: modelContext.container)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if startupCoordinator.isLoading {
            ProgressView("Preparing your library...")
        } else {
            LibraryView()
        }
    }
}

#Preview {
    let container = AppBootstrap.makeRecoveryContainer() ?? {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let schema = Schema([Book.self, Chapter.self, Folder.self, ABSServer.self])
        return try! ModelContainer(for: schema, configurations: [config])
    }()
    ContentView(storageBootstrapState: .ready(container))
        .environmentObject(ImportService.shared)
        .modelContainer(for: [Book.self, Chapter.self, Folder.self, ABSServer.self], inMemory: true)
}
