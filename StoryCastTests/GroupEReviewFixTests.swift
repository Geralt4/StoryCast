import Foundation
import XCTest
@testable import StoryCast

/// Regression tests for the Group E final review and security hardening fixes.
@MainActor
final class GroupEReviewFixTests: XCTestCase {

    // MARK: - R1 — extendBy must update timerEndDate

    func testExtendByUpdatesTotalTime() {
        let timer = SleepTimerService.shared
        timer.start(minutes: 1)
        XCTAssertEqual(timer.totalTime, 60)
        timer.extendBy(minutes: 5)
        XCTAssertEqual(timer.totalTime, 360)
        XCTAssertEqual(timer.remainingTime, 360)
        timer.cancel(announce: false)
    }

    func testExtendByFromZeroUpdatesCorrectly() {
        let timer = SleepTimerService.shared
        timer.start(minutes: 1)
        XCTAssertEqual(timer.remainingTime, 60)
        timer.extendBy(minutes: 2)
        XCTAssertEqual(timer.remainingTime, 180)
        XCTAssertEqual(timer.totalTime, 180)
        timer.cancel(announce: false)
    }

    // MARK: - R2 — pause preserves remainingTime

    func testCancelResetsTimerEndDate() {
        let timer = SleepTimerService.shared
        timer.start(minutes: 5)
        XCTAssertEqual(timer.isActive, true)
        XCTAssertEqual(timer.remainingTime, 300)
        timer.cancel(announce: false)
        XCTAssertEqual(timer.isActive, false)
        XCTAssertEqual(timer.remainingTime, 0)
    }

    // MARK: - SEC2 — AudiobookshelfAuth device ID methods

    func testABSDeviceIDIsConsistent() {
        let id1 = AudiobookshelfAuth.absDeviceID()
        let id2 = AudiobookshelfAuth.absDeviceID()
        XCTAssertFalse(id1.isEmpty, "Device ID should not be empty")
        XCTAssertEqual(id1, id2, "Device ID should be consistent across calls")

        // Clean up after test
        AudiobookshelfAuth.deleteABSDeviceID()
    }

    func testABSDeviceIDMigratesFromUserDefaults() {
        // Simulate pre-migration state
        let testID = "test-device-id-12345"
        UserDefaults.standard.set(testID, forKey: "StoryCast.DeviceID")

        let id = AudiobookshelfAuth.absDeviceID()
        XCTAssertEqual(id, testID, "Should migrate from UserDefaults")
        XCTAssertNil(UserDefaults.standard.string(forKey: "StoryCast.DeviceID"), "UserDefaults key should be removed after migration")

        // Clean up
        AudiobookshelfAuth.deleteABSDeviceID()
    }
}
