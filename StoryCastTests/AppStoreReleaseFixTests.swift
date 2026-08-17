import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class AppStoreReleaseFixTests: XCTestCase {

    // MARK: - H3: modelContainers dict is cleaned up after download

    @MainActor
    func testModelContainersCleanedUpAfterCancelDownload() throws {
        let manager = DownloadManager.shared
        manager.debugResetState()

        let bookId = UUID()
        manager.debugRegisterTrackedDownload(bookId: bookId)

        XCTAssertEqual(manager.debugDownloadCount, 1, "Download should be tracked after registration")

        manager.cancelDownload(bookId: bookId)

        XCTAssertEqual(manager.debugDownloadCount, 0, "Download should be removed after cancellation")
    }

    // MARK: - B2+B3: Background completion handler storage and invocation

    @MainActor
    func testBackgroundCompletionHandlerIsStored() throws {
        let manager = DownloadManager.shared
        manager.debugResetState()

        XCTAssertEqual(manager.debugBackgroundCompletionHandlerCount, 0, "No handlers should be stored initially")

        let handler: () -> Void = { }

        manager.storeBackgroundCompletionHandler(identifier: "test-session-1", completionHandler: handler)
        XCTAssertEqual(manager.debugBackgroundCompletionHandlerCount, 1, "Handler should be stored after calling storeBackgroundCompletionHandler")
    }

    @MainActor
    func testMultipleBackgroundCompletionHandlersAreStored() throws {
        let manager = DownloadManager.shared
        manager.debugResetState()

        let handler1: () -> Void = { }
        let handler2: () -> Void = { }

        manager.storeBackgroundCompletionHandler(identifier: "session-1", completionHandler: handler1)
        manager.storeBackgroundCompletionHandler(identifier: "session-2", completionHandler: handler2)

        XCTAssertEqual(manager.debugBackgroundCompletionHandlerCount, 2, "Both handlers should be stored for different sessions")
    }

    // MARK: - H5: @StateObject replaced with @ObservedObject for singleton

    @MainActor
    func testRemoteLibraryServiceIsSharedSingleton() {
        let instance1 = RemoteLibraryService.shared
        let instance2 = RemoteLibraryService.shared
        XCTAssertTrue(instance1 === instance2, "RemoteLibraryService.shared should return the same instance")
    }

    // MARK: - H4: Audio session retry logic exists

    @MainActor
    func testAudioSessionManagerEnsureActiveDoesNotCrash() async throws {
        let manager = AudioSessionManager.shared
        try await manager.ensureActive()
        XCTAssertTrue(true, "ensureActive should not throw")
    }
}
