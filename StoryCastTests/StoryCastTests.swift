import XCTest
@testable import StoryCast

nonisolated final class StoryCastTests: XCTestCase {

    // MARK: - PlaybackSettings Tests

    @MainActor
    func testPlaybackSettingsLoadDefaults() {
        let defaultsKey = PlaybackSettings.userDefaultsKey
        UserDefaults.standard.removeObject(forKey: defaultsKey)

        let settings = PlaybackSettings.load()

        XCTAssertEqual(settings.skipForwardSeconds, 30.0)
        XCTAssertEqual(settings.skipBackwardSeconds, 15.0)
        XCTAssertEqual(settings.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(settings.autoPlayNextChapter, true)
    }

    @MainActor
    func testPlaybackSettingsSaveAndLoad() {
        var settings = PlaybackSettings()
        settings.skipForwardSeconds = 45.0
        settings.skipBackwardSeconds = 20.0
        settings.defaultPlaybackSpeed = 1.5
        settings.autoPlayNextChapter = false

        settings.save()
        let loaded = PlaybackSettings.load()

        XCTAssertEqual(loaded.skipForwardSeconds, 45.0)
        XCTAssertEqual(loaded.skipBackwardSeconds, 20.0)
        XCTAssertEqual(loaded.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(loaded.autoPlayNextChapter, false)
    }

    @MainActor
    func testPlaybackSettingsResetToDefaults() {
        var settings = PlaybackSettings()
        settings.skipForwardSeconds = 60.0
        settings.save()

        PlaybackSettings.resetToDefaults()
        let loaded = PlaybackSettings.load()

        XCTAssertEqual(loaded.skipForwardSeconds, 30.0)
    }

    // MARK: - SleepTimerSettings Tests

    @MainActor
    func testSleepTimerSettingsLoadDefaults() {
        let defaultsKey = SleepTimerSettings.userDefaultsKey
        UserDefaults.standard.removeObject(forKey: defaultsKey)

        let settings = SleepTimerSettings.load()

        XCTAssertEqual(settings.defaultDurationMinutes, 30)
    }

    @MainActor
    func testSleepTimerSettingsSaveAndLoad() {
        var settings = SleepTimerSettings()
        settings.defaultDurationMinutes = 45

        settings.save()
        let loaded = SleepTimerSettings.load()

        XCTAssertEqual(loaded.defaultDurationMinutes, 45)
    }

    @MainActor
    func testSleepTimerSettingsResetToDefaults() {
        var settings = SleepTimerSettings()
        settings.defaultDurationMinutes = 60
        settings.save()

        SleepTimerSettings.resetToDefaults()
        let loaded = SleepTimerSettings.load()

        XCTAssertEqual(loaded.defaultDurationMinutes, 30)
    }

    // MARK: - TimeFormatter Tests

    @MainActor
    func testTimeFormatterPlayback() {
        XCTAssertEqual(TimeFormatter.playback(0), "0:00")
        XCTAssertEqual(TimeFormatter.playback(59), "0:59")
        XCTAssertEqual(TimeFormatter.playback(60), "1:00")
        XCTAssertEqual(TimeFormatter.playback(3599), "59:59")
        XCTAssertEqual(TimeFormatter.playback(3600), "1:00:00")
        XCTAssertEqual(TimeFormatter.playback(7265), "2:01:05")
    }

    @MainActor
    func testTimeFormatterCompact() {
        XCTAssertEqual(TimeFormatter.compact(0), "0:00")
        XCTAssertEqual(TimeFormatter.compact(59), "0:59")
        XCTAssertEqual(TimeFormatter.compact(60), "1:00")
        XCTAssertEqual(TimeFormatter.compact(125), "2:05")
    }

    @MainActor
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

    @MainActor
    func testSupportedFormatsIsSupported() {
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.mp3")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.MP3")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.m4a")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.m4b")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.wav")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.aiff")))
        XCTAssertTrue(SupportedFormats.isSupported(URL(fileURLWithPath: "test.aif")))

        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test.mp4")))
        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test.txt")))
        XCTAssertFalse(SupportedFormats.isSupported(URL(fileURLWithPath: "test")))
    }

    @MainActor
    func testSupportedFormatsGetDisplayName() {
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.mp3")), "MP3 Audio")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.m4a")), "MPEG-4 Audio (M4A/M4B)")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.wav")), "WAV Audio")
        XCTAssertEqual(SupportedFormats.getDisplayName(for: URL(fileURLWithPath: "test.unknown")), "Audio File")
    }

    @MainActor
    func testSupportedFormatsIsM4B() {
        XCTAssertTrue(SupportedFormats.isM4B(URL(fileURLWithPath: "test.m4b")))
        XCTAssertTrue(SupportedFormats.isM4B(URL(fileURLWithPath: "test.M4B")))
        XCTAssertFalse(SupportedFormats.isM4B(URL(fileURLWithPath: "test.m4a")))
        XCTAssertFalse(SupportedFormats.isM4B(URL(fileURLWithPath: "test.mp3")))
    }
}