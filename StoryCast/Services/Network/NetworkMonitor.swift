import Foundation
import Network
import Combine

/// Tracks device network connectivity using NWPathMonitor.
/// Publish `isConnected` and `isExpensive` (cellular) so the UI and
/// sync layer can react to connectivity changes.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isExpensive: Bool = false   // true when on cellular

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "StoryCast.NetworkMonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
