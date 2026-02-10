#if os(iOS)
import UIKit
#endif

enum HapticImpactStyle {
    case light
    case medium
    case heavy
}

enum HapticNotificationType {
    case success
    case warning
    case error
}

@MainActor
struct HapticManager {
    #if os(iOS)
    private static let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    static func impact(_ style: HapticImpactStyle) {
        #if os(iOS)
        switch style {
        case .light:
            lightImpactGenerator.impactOccurred()
        case .medium:
            mediumImpactGenerator.impactOccurred()
        case .heavy:
            heavyImpactGenerator.impactOccurred()
        }
        #endif
    }

    static func selection() {
        #if os(iOS)
        selectionGenerator.selectionChanged()
        #endif
    }

    static func notification(_ type: HapticNotificationType) {
        #if os(iOS)
        notificationGenerator.notificationOccurred(uiNotificationType(for: type))
        #endif
    }

    #if os(iOS)
    private static func uiNotificationType(for type: HapticNotificationType) -> UINotificationFeedbackGenerator.FeedbackType {
        switch type {
        case .success:
            return .success
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
    #endif
}
