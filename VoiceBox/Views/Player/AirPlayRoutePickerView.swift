import SwiftUI
#if os(iOS)
import AVKit
#endif

/// SwiftUI wrapper for AVRoutePickerView to enable AirPlay selection
struct AirPlayRoutePickerView: View {
    var body: some View {
        #if os(iOS)
        AirPlayButtonRepresentable()
            .frame(width: LayoutDefaults.secondaryControlWidth, height: LayoutDefaults.secondaryControlWidth)
            .accessibilityLabel("AirPlay")
            .accessibilityHint("Choose audio output device")
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
/// UIViewRepresentable wrapper for AVRoutePickerView
struct AirPlayButtonRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.backgroundColor = .clear
        routePickerView.tintColor = .label
        routePickerView.activeTintColor = .systemBlue
        routePickerView.prioritizesVideoDevices = false
        return routePickerView
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Update tint color based on current color scheme if needed
        uiView.tintColor = .label
        uiView.activeTintColor = .systemBlue
    }
}
#endif

#Preview {
    AirPlayRoutePickerView()
        .padding()
}
