import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    let storageBootstrapState: StorageBootstrapState

    @StateObject private var startupCoordinator = StartupCoordinator()

    var body: some View {
        Group {
            switch storageBootstrapState {
            case .ready:
                contentBody
            case .failed(let failure):
                StorageRecoveryView(failure: failure)
            case .unrecoverable(let error):
                FatalErrorView(error: error, onReset: {
                    Task {
                        await StorageManager.shared.resetAllData()
                    }
                })
            }
        }
        .task {
            guard case .ready = storageBootstrapState else { return }
            await startupCoordinator.startIfNeeded(container: modelContext.container)
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
        } else {
            LibraryView()
        }
    }
}

#Preview {
    let container = AppBootstrap.makeRecoveryContainer()!
    ContentView(storageBootstrapState: .ready(container))
        .environmentObject(ImportService.shared)
        .modelContainer(for: [Book.self, Chapter.self, Folder.self, ABSServer.self], inMemory: true)
}
