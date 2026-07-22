import Foundation
import XCTest
@testable import StoryCast

@MainActor
final class AppRecoveryFlowTests: XCTestCase {
    func testOnlyReadyBootstrapStateAllowsLibraryAccess() throws {
        let container = try XCTUnwrap(AppBootstrap.makeRecoveryContainer())
        XCTAssertTrue(StorageBootstrapState.ready(container).allowsLibraryAccess)
        XCTAssertFalse(StorageBootstrapState.failed(StorageInitializationFailure(
            message: "failed",
            recoverySuggestion: "restart",
            technicalDetails: "details"
        )).allowsLibraryAccess)
        XCTAssertFalse(StorageBootstrapState.versionMismatch(
            .versionMismatchDetected(details: "mismatch")
        ).allowsLibraryAccess)
        XCTAssertFalse(StorageBootstrapState.unrecoverable(
            StorageUnrecoverableError(message: "failed")
        ).allowsLibraryAccess)
    }

    func testRecoverySuccessReturnsRestartRequiredWithoutActivatingContainer() async {
        let backupURL = URL(fileURLWithPath: "/tmp/storycast-backup", isDirectory: true)

        let outcome = await AppBootstrap.startFresh {
            .restartRequired(backupURL: backupURL)
        }

        XCTAssertEqual(outcome, .restartRequired(backupURL: backupURL))
    }

    func testRecoveryFailurePreservesActionableMessage() async {
        let outcome = await AppBootstrap.startFresh {
            .failed(StorageUnrecoverableError(message: "Backup verification failed"))
        }

        XCTAssertEqual(
            outcome,
            .failed(StorageUnrecoverableError(message: "Backup verification failed"))
        )
        if case .failed(let error) = outcome {
            XCTAssertEqual(error.localizedDescription, "Backup verification failed")
        }
    }

    func testConcurrentRecoveryRequestsShareOneOperation() async {
        let counter = RecoveryOperationCounter()

        async let first = AppBootstrap.startFresh {
            await counter.perform()
        }
        async let second = AppBootstrap.startFresh {
            await counter.perform()
        }

        let firstOutcome = await first
        let secondOutcome = await second
        let operationCount = await counter.count
        XCTAssertEqual(firstOutcome, .restartRequired(backupURL: nil))
        XCTAssertEqual(secondOutcome, .restartRequired(backupURL: nil))
        XCTAssertEqual(operationCount, 1)
    }
}

private actor RecoveryOperationCounter {
    private(set) var count = 0

    func perform() async -> StorageRecoveryOutcome {
        count += 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        return .restartRequired(backupURL: nil)
    }
}
