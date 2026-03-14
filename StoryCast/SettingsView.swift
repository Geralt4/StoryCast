import SwiftUI
import SwiftData

struct SettingsView: View {
    // Load saved settings
    @State private var playbackSettings = PlaybackSettings.load()
    @State private var sleepTimerSettings = SleepTimerSettings.load()
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.automatic.rawValue
    
    // Server configuration
    @Query(sort: \ABSServer.createdAt) private var servers: [ABSServer]

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Playback")) {
                    HStack {
                        Text("Skip Forward")
                        Spacer()
                        Text("\(Int(playbackSettings.skipForwardSeconds))s")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $playbackSettings.skipForwardSeconds, in: PlaybackRanges.skipSeconds, step: 5)
                        .onChange(of: playbackSettings.skipForwardSeconds) { _, _ in
                            HapticManager.selection()
                            playbackSettings.save()
                        }
                        .accessibilityLabel("Skip forward duration")
                        .accessibilityValue("\(Int(playbackSettings.skipForwardSeconds)) seconds")

                    HStack {
                        Text("Skip Backward")
                        Spacer()
                        Text("\(Int(playbackSettings.skipBackwardSeconds))s")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $playbackSettings.skipBackwardSeconds, in: PlaybackRanges.skipSeconds, step: 5)
                        .onChange(of: playbackSettings.skipBackwardSeconds) { _, _ in
                            HapticManager.selection()
                            playbackSettings.save()
                        }
                        .accessibilityLabel("Skip backward duration")
                        .accessibilityValue("\(Int(playbackSettings.skipBackwardSeconds)) seconds")

                    HStack {
                        Text("Default Speed")
                        Spacer()
                        Text(String(format: "%.1fx", playbackSettings.defaultPlaybackSpeed))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $playbackSettings.defaultPlaybackSpeed, in: PlaybackRanges.playbackSpeed, step: 0.1)
                        .onChange(of: playbackSettings.defaultPlaybackSpeed) { _, _ in
                            HapticManager.selection()
                            playbackSettings.save()
                        }
                        .accessibilityLabel("Default playback speed")
                        .accessibilityValue(String(format: "%.1f times", playbackSettings.defaultPlaybackSpeed))

                    Toggle("Auto-play Next Chapter", isOn: $playbackSettings.autoPlayNextChapter)
                        .onChange(of: playbackSettings.autoPlayNextChapter) { _, _ in
                            HapticManager.impact(.light)
                            playbackSettings.save()
                        }
                        .accessibilityLabel("Auto-play next chapter")
                        .accessibilityValue(playbackSettings.autoPlayNextChapter ? "On" : "Off")
                }

                Section(header: Text("Sleep Timer")) {
                    Picker("Default Duration", selection: $sleepTimerSettings.defaultDurationMinutes) {
                        ForEach(SleepTimerDefaults.availableDurations, id: \.self) { duration in
                            Text("\(duration) minutes").tag(duration)
                        }
                    }
                    .onChange(of: sleepTimerSettings.defaultDurationMinutes) { _, _ in
                        sleepTimerSettings.save()
                    }
                }

                Section(header: Text("Appearance")) {
                    Picker("Appearance", selection: appearanceModeBinding) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Audiobookshelf")) {
                    NavigationLink(destination: ServerListView()) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.blue)
                            Text("Servers")
                            Spacer()
                            if !servers.isEmpty {
                                Text("\(servers.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(buildNumber)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Support")) {
                    Button(action: {
                        openSupportEmail()
                    }) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.blue)
                            Text("Contact Support")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: TipJarView()) {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                            Text("Support Developer")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .automatic },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    private func openSupportEmail() {
        guard let url = URL(string: "mailto:\(AppConstants.supportEmail)?subject=StoryCast%20-%20Support&body=\(emailBody())") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func emailBody() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let device = UIDevice.current.model
        let iOSVersion = UIDevice.current.systemVersion

        return """
        
        ---
        App Information:
        Version: \(version)
        Build: \(build)
        Device: \(device)
        iOS: \(iOSVersion)
        
        Please describe your issue or feature request below:
        
        """.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
