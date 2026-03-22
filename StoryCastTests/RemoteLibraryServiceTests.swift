import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class RemoteLibraryServiceTests: XCTestCase {
    override func setUp() async throws {
        await MainActor.run {
            RemoteLibraryService.shared.debugResetUIState()
        }
    }

    override func tearDown() {
        Task { @MainActor in
            RemoteLibraryService.shared.debugResetUIState()
        }
    }

    @MainActor
    func testRetryCoverArtDownloadRemovesTrackedFailure() {
        let service = RemoteLibraryService.shared
        let server = ABSServer(name: "Remote", url: "https://example.com", username: "tester")
        let bookId = UUID()

        service.debugSetActiveServer(server)
        service.debugRecordCoverArtFailure(bookId: bookId, serverId: server.id, itemId: "item-1", retryCount: 2)

        XCTAssertEqual(service.coverArtFailures.count, 1)

        XCTAssertNoThrow(try service.retryCoverArtDownload(for: bookId, container: makeInMemoryContainer()))

        XCTAssertTrue(service.coverArtFailures.isEmpty)
    }

    @MainActor
    func testRetryAllCoverArtDownloadsClearsTrackedFailuresForActiveServer() {
        let service = RemoteLibraryService.shared
        let server = ABSServer(name: "Remote", url: "https://example.com", username: "tester")

        service.debugSetActiveServer(server)
        service.debugRecordCoverArtFailure(bookId: UUID(), serverId: server.id, itemId: "item-1")
        service.debugRecordCoverArtFailure(bookId: UUID(), serverId: server.id, itemId: "item-2")

        XCTAssertEqual(service.coverArtFailures.count, 2)

        XCTAssertNoThrow(try service.retryAllCoverArtDownloads(container: makeInMemoryContainer()))

        XCTAssertTrue(service.coverArtFailures.isEmpty)
    }

    @MainActor
    func testCancelAllCoverArtDownloadsCancelsTrackedTasks() {
        let service = RemoteLibraryService.shared

        let firstTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let secondTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        service.debugRegisterCoverArtTask(firstTask, for: UUID())
        service.debugRegisterCoverArtTask(secondTask, for: UUID())
        XCTAssertEqual(service.debugCoverArtTaskCount, 2)

        service.cancelAllCoverArtDownloads()

        XCTAssertEqual(service.debugCoverArtTaskCount, 0)
        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertTrue(secondTask.isCancelled)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
    }
}
