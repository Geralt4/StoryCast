import Foundation
import os

enum AppLogger {
    private final class BundleToken {}

    nonisolated private static let subsystem: String = {
        Bundle(for: BundleToken.self).bundleIdentifier ?? "StoryCast"
    }()

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let importService = Logger(subsystem: subsystem, category: "import")
    nonisolated static let playback = Logger(subsystem: subsystem, category: "playback")
    nonisolated static let storage = Logger(subsystem: subsystem, category: "storage")
    nonisolated static let metadata = Logger(subsystem: subsystem, category: "metadata")
    nonisolated static let settings = Logger(subsystem: subsystem, category: "settings")
    nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")
    nonisolated static let remoteCommand = Logger(subsystem: subsystem, category: "remoteCommand")
    nonisolated static let storeKit = Logger(subsystem: subsystem, category: "storeKit")
}
