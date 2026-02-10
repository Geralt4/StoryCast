import SwiftUI

enum AppearanceMode: String, CaseIterable, Codable {
    case automatic
    case light
    case dark

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
