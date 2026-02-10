import XCTest
@testable import VoiceBox

final class VoiceBoxTests: XCTestCase {

    // MARK: - PlaybackSettings Tests

    func testPlaybackSettingsLoadDefaults() {
        // Given: Clean UserDefaults
        let defaultsKey = PlaybackSettings.userDefaultsKey
        UserDefaults.standard.removeObject(forKey: defaultsKey)

        // When: Load settings
        let settings = PlaybackSettings.load()

        // Then: Should have default values
        XCTAssertEqual(settings.skipForwardSeconds, 30.0)
        XCTAssertEqual(settings.skipBackwardSeconds, 15.0)
        XCTAssertEqual(settings.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(settings.autoPlayNextChapter, true)
    }

    func testPlaybackSettingsSaveAndLoad() {
        // Given: Modified settings
        var settings = PlaybackSettings()
        settings.skipForwardSeconds = 45.0
        settings.skipBackwardSeconds = 20.0
        settings.defaultPlaybackSpeed = 1.5
        settings.autoPlayNextChapter = false

        // When: Save and load
        settings.save()
        let loaded = PlaybackSettings.load()

        // Then: Should match saved values
        XCTAssertEqual(loaded.skipForwardSeconds, 45.0)
        XCTAssertEqual(loaded.skipBackwardSeconds, 20.0)
        XCTAssertEqual(loaded.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(loaded.autoPlayNextChapter, false)
    }

    func testPlaybackSettingsResetToDefaults() {
        // Given: Modified settings saved
        var settings = PlaybackSettings()
        settings.skipForwardSeconds = 60.0
        settings.save()

        // When: Reset
        PlaybackSettings.resetToDefaults()
        let loaded = PlaybackSettings.load()

        // Then: Should be default
        XCTAssertEqual(loaded.skipForwardSeconds, 30.0)
    }

    // MARK: - SleepTimerSettings Tests

    func testSleepTimerSettingsLoadDefaults() {
        // Given: Clean UserDefaults
        let defaultsKey = SleepTimerSettings.userDefaultsKey
        UserDefaults.standard.removeObject(forKey: defaultsKey)

        // When: Load settings
        let settings = SleepTimerSettings.load()

        // Then: Should have default values
        XCTAssertEqual(settings.defaultDurationMinutes, 30)
    }

    func testSleepTimerSettingsSaveAndLoad() {
        // Given: Modified settings
        var settings = SleepTimerSettings()
        settings.defaultDurationMinutes = 45

        // When: Save and load
        settings.save()
        let loaded = SleepTimerSettings.load()

        // Then: Should match saved values
        XCTAssertEqual(loaded.defaultDurationMinutes, 45)
    }

    func testSleepTimerSettingsResetToDefaults() {
        // Given: Modified settings saved
        var settings = SleepTimerSettings()
        settings.defaultDurationMinutes = 60
        settings.save()

        // When: Reset
        SleepTimerSettings.resetToDefaults()
        let loaded = SleepTimerSettings.load()

        // Then: Should be default
        XCTAssertEqual(loaded.defaultDurationMinutes, 30)
    }

    // MARK: - TimeFormatter Tests

    func testTimeFormatterPlayback() {
        // Test various time formats
        XCTAssertEqual(TimeFormatter.playback(0), "0:00")
        XCTAssertEqual(TimeFormatter.playback(59), "0:59")
        XCTAssertEqual(TimeFormatter.playback(60), "1:00")
        XCTAssertEqual(TimeFormatter.playback(3599), "59:59")
        XCTAssertEqual(TimeFormatter.playback(3600), "1:00:00")
        XCTAssertEqual(TimeFormatter.playback(7265), "2:01:05")
    }

    func testTimeFormatterCompact() {
        XCTAssertEqual(TimeFormatter.compact(0), "0:00")
        XCTAssertEqual(TimeFormatter.compact(59), "0:59")
        XCTAssertEqual(TimeFormatter.compact(60), "1:00")
        XCTAssertEqual(TimeFormatter.compact(125), "2:05")
    }

    func testTimeFormatterHuman() {
        XCTAssertEqual(TimeFormatter.human(0), "0s")
        XCTAssertEqual(TimeFormatter.human(30), "30s")
        XCTAssertEqual(TimeFormatter.human(60), "1m")
        XCTAssertEqual(TimeFormatter.human(90), "1m 30s")
        XCTAssertEqual(TimeFormatter.human(3600), "1h")
        XCTAssertEqual(TimeFormatter.human(3660), "1h 1m")
        XCTAssertEqual(TimeFormatter.human(3720), "1h 2m")
    }

    // MARK: - SupportedFormats Tests

    func testSupportedFormatsIsSupported() {
        // Supported formats
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.mp3")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.MP3")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.m4a")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.m4b")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.wav")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.aiff")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.aif")))

        // Unsupported formats
        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test.mp4")))
        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test.txt")))
        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test")))
    }

    func testSupportedFormatsGetDisplayName() {
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.mp3")), "MP3 Audio")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.m4a")), "MPEG-4 Audio (M4A/M4B)")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.wav")), "WAV Audio")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.unknown")), "Audio File")
    }

    func testSupportedFormatsIsM4B() {
        XCTAssertTrue(SupportedFormats.isM4B(URL(fileURLWithPath: "test.m4b")))
        XCTAssertTrue(SupportedFormats.isM4B(URL(fileURLWithPath: "test.M4B")))
        XCTAssertFalse(SupportedFormats.isM4B(URL(fileURLWithPath: "test.m4a")))
        XCTAssertFalse(SupportedFormats.isM4B(URL(fileURLWithPath: "test.mp3")))
    }

    // MARK: - Setup/Teardown

    override func setUpWithError() throws {
        // Snapshot UserDefaults before each test
        snapshotUserDefaults()
    }

    override func tearDownWithError() throws {
        // Restore UserDefaults after each test
        restoreUserDefaults()
    }

    private var userDefaultsSnapshot: [String: Any] = [:]

    private func snapshotUserDefaults() {
        let keys = [PlaybackSettings.userDefaultsKey, SleepTimerSettings.userDefaultsKey]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                userDefaultsSnapshot[key] = value
            }
        }
    }

    private func restoreUserDefaults() {
        for (key, value) in userDefaultsSnapshot {
            UserDefaults.standard.set(value, forKey: key)
        }
        userDefaultsSnapshot.removeAll()
    }
}