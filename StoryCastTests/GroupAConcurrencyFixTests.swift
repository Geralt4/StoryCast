import XCTest
@testable import StoryCast

/// Regression tests for the Group A bug-hunt fixes.
///
/// Background: a deep code review surfaced 22 bugs across the
/// concurrency, import, and player layers. These tests pin down the
/// most important ones so they cannot regress.
nonisolated final class GroupAConcurrencyFixTests: XCTestCase {

    // MARK: - H1 — ImportOperationGate must not enable concurrent imports

    nonisolated func testCancelAllDoesNotEnableConcurrentImport() async throws {
        // The H1 bug: cancelAll() reset isExecuting = false while the old
        // import was still running, so a new acquire() succeeded
        // immediately and two imports ran concurrently.
        //
        // We verify the simplest invariant: the gate's `isExecuting` flag
        // (observable via hasPendingRequests) must stay true after
        // cancelAll() if the original operation hasn't released.
        let gate = ImportOperationGate()

        // First acquire — no contention, completes immediately.
        try await gate.acquire(requestID: UUID())
        let pendingAfterAcquire = await gate.hasPendingRequests
        XCTAssertTrue(pendingAfterAcquire, "Gate must report pending state while held")

        // Cancel the current request. Since the request is still executing
        // (we haven't called release), the gate must remain held.
        await gate.cancelAll()
        let pendingAfterCancel = await gate.hasPendingRequests
        XCTAssertTrue(
            pendingAfterCancel,
            "Gate must remain held after cancelAll() because the executing operation hasn't released"
        )

        // After release, the gate must be free.
        await gate.release()
        let pendingAfterRelease = await gate.hasPendingRequests
        XCTAssertFalse(
            pendingAfterRelease,
            "Gate must be free after release()"
        )
    }

    // MARK: - M9 — isSafeRelativePath must reject Unicode normalization

    nonisolated func testIsSafeRelativePathRejectsFullWidthDots() {
        // The full-width period (U+FF0E) is canonically equivalent to "."
        // after NFKC normalization. If it slipped past the literal "."
        // check, a filename like "\u{FF0E}\u{FF0E}/etc" could escape the
        // managed library directory.
        let fullWidthDots = "\u{FF0E}\u{FF0E}"
        XCTAssertFalse(
            StorageCleanupCoordinator.isSafeRelativePath(fullWidthDots),
            "Full-width dots must be rejected (NFKC normalization bypass)"
        )
    }

    nonisolated func testIsSafeRelativePathAcceptsPlainAscii() {
        XCTAssertTrue(StorageCleanupCoordinator.isSafeRelativePath("book123.m4b"))
        XCTAssertTrue(StorageCleanupCoordinator.isSafeRelativePath("cover art.jpg"))
    }

    nonisolated func testIsSafeRelativePathRejectsTraversal() {
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath(".."))
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath("."))
        XCTAssertFalse(StorageCleanupCoordinator.isSafeRelativePath("foo/bar"))
    }
}
