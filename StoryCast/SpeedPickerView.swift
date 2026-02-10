import SwiftUI

/// Sheet view for selecting playback speed
struct SpeedPickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    
    let speedOptions: [Float] = PlaybackDefaults.speedOptions
    
    var body: some View {
        NavigationStack {
            List(speedOptions, id: \.self) { speed in
                let isSelected = abs(audioPlayer.playbackRate - speed) < MathDefaults.floatEpsilon
                Button(action: {
                    HapticManager.impact(.light)
                    audioPlayer.setPlaybackRate(speed)
                    dismiss()
                }) {
                    HStack {
                        Text(String(format: "%.1fx", speed))
                            .font(.headline)
                        
                        Spacer()
                        
                         if isSelected {
                               Image(systemName: "checkmark")
                                   .foregroundColor(.blue)
                           }
                    }
                    .padding(.vertical, LayoutDefaults.smallSpacing)
                }
                .tint(.primary) // Keep text black/primary
                .accessibilityLabel("Playback speed \(String(format: "%.1f times", speed))")
                .accessibilityValue(isSelected ? "Selected" : "")
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
