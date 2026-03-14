import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class ServerRemovalServiceTests: XCTestCase {
    @MainActor
    func testRemoveServerKeepsServerAndTokenWhenRemoteCleanupFails() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        try context.save()

        let service = ServerRemovalService(
            remoteBookRemoval: { _, _ in throw TestError.remoteCleanupFailed },
            loadToken: { _ in "token-123" },
            deleteToken: { _ in XCTFail("Token should not be deleted when cleanup fails") },
            saveToken: { _, _ in XCTFail("Token should not need restoration when cleanup fails") },
            persistServerDeletion: { _, _ in XCTFail("Server should not be deleted when cleanup fails") }
        )

        do {
            try await service.removeServer(server, modelContext: context)
            XCTFail("Expected remote cleanup failure")
        } catch let error as ServerRemovalService.RemovalError {
            guard case .remoteCleanupFailed = error else {
                return XCTFail("Unexpected removal error: \(error)")
            }
        }

        let remainingServers = try context.fetch(FetchDescriptor<ABSServer>())
        XCTAssertEqual(remainingServers.count, 1)
        XCTAssertEqual(remainingServers.first?.id, server.id)
    }

    @MainActor
    func testRemoveServerRestoresTokenWhenPersistenceFails() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        try context.save()

        let recorder = TokenRecorder()
        let service = ServerRemovalService(
            remoteBookRemoval: { _, _ in },
            loadToken: { _ in "token-456" },
            deleteToken: { serverURL in
                await recorder.recordDeletion(url: serverURL)
            },
            saveToken: { token, serverURL in
                await recorder.recordRestore(token: token, url: serverURL)
            },
            persistServerDeletion: { _, _ in throw TestError.persistenceFailed }
        )

        do {
            try await service.removeServer(server, modelContext: context)
            XCTFail("Expected persistence failure")
        } catch let error as ServerRemovalService.RemovalError {
            guard case .persistenceFailed = error else {
                return XCTFail("Unexpected removal error: \(error)")
            }
        }

        let deletedTokenURL = await recorder.deletedTokenURL
        let restoredToken = await recorder.restoredToken
        XCTAssertEqual(deletedTokenURL, server.normalizedURL)
        XCTAssertEqual(restoredToken?.token, "token-456")
        XCTAssertEqual(restoredToken?.url, server.normalizedURL)

        let remainingServers = try context.fetch(FetchDescriptor<ABSServer>())
        XCTAssertEqual(remainingServers.count, 1)
        XCTAssertEqual(remainingServers.first?.id, server.id)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
    }
}

private enum TestError: Error {
    case remoteCleanupFailed
    case persistenceFailed
}

private actor TokenRecorder {
    private(set) var deletedTokenURL: String?
    private(set) var restoredToken: (token: String, url: String)?

    func recordDeletion(url: String) {
        deletedTokenURL = url
    }

    func recordRestore(token: String, url: String) {
        restoredToken = (token, url)
    }
}
