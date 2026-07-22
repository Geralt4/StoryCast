import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class ServerRemovalServiceTests: XCTestCase {
    @MainActor
    func testTokenDeletionFailurePreservesServerAndBooks() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        context.insert(Book(
            title: "Remote Book", duration: 100,
            isRemote: true, serverId: server.id
        ))
        try context.save()

        let service = ServerRemovalService(
            deleteToken: { _ in throw TestError.tokenDeletionFailed },
            persistFinalDeletion: { _, _ in XCTFail("Final deletion should not run when token fails") }
        )

        do {
            try await service.removeServer(server, modelContext: context)
            XCTFail("Expected token deletion failure")
        } catch let error as ServerRemovalService.RemovalError {
            guard case .tokenDeletionFailed = error else {
                return XCTFail("Unexpected removal error: \(error)")
            }
        }

        let remainingServers = try context.fetch(FetchDescriptor<ABSServer>())
        XCTAssertEqual(remainingServers.count, 1)
        XCTAssertEqual(remainingServers.first?.id, server.id)
        XCTAssertFalse(remainingServers.first?.isActive ?? true)

        let journals = try context.fetch(FetchDescriptor<ServerRemovalJournalEntry>())
        XCTAssertEqual(journals.count, 1)
        XCTAssertEqual(journals.first?.phaseRaw, "prepared")

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
    }

    @MainActor
    func testFinalDeletionFailurePreservesServerAndBooks() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        try context.save()

        let service = ServerRemovalService(
            deleteToken: { _ in },
            persistFinalDeletion: { _, _ in throw TestError.persistenceFailed }
        )

        do {
            try await service.removeServer(server, modelContext: context)
            XCTFail("Expected persistence failure")
        } catch let error as ServerRemovalService.RemovalError {
            guard case .persistenceFailed = error else {
                return XCTFail("Unexpected removal error: \(error)")
            }
        }

        let remainingServers = try context.fetch(FetchDescriptor<ABSServer>())
        XCTAssertEqual(remainingServers.count, 1)

        let journals = try context.fetch(FetchDescriptor<ServerRemovalJournalEntry>())
        XCTAssertEqual(journals.count, 1)
        XCTAssertEqual(journals.first?.phaseRaw, "credentialRemoved")
    }

    @MainActor
    func testSuccessfulRemovalDeletesServerBooksAndJournal() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        context.insert(Book(
            title: "Remote Book", duration: 100,
            isRemote: true, serverId: server.id
        ))
        try context.save()

        let service = ServerRemovalService(
            deleteToken: { _ in },
            persistFinalDeletion: { serverId, cont in
                try await MainActor.run {
                    let ctx = ModelContext(cont)
                    let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                    guard let srv = try ctx.fetch(descriptor).first else { return }
                    let books = try ctx.fetch(FetchDescriptor<Book>(
                        predicate: #Predicate { $0.serverId == serverId }
                    ))
                    for book in books {
                        try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: nil, in: ctx)
                    }
                    let journalDescriptor = FetchDescriptor<ServerRemovalJournalEntry>(
                        predicate: #Predicate { $0.serverID == serverId }
                    )
                    for entry in try ctx.fetch(journalDescriptor) {
                        ctx.delete(entry)
                    }
                    ctx.delete(srv)
                    try ctx.save()
                }
            }
        )

        try await service.removeServer(server, modelContext: context)

        let remainingServers = try context.fetch(FetchDescriptor<ABSServer>())
        XCTAssertTrue(remainingServers.isEmpty)

        let journals = try context.fetch(FetchDescriptor<ServerRemovalJournalEntry>())
        XCTAssertTrue(journals.isEmpty)

        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertTrue(books.isEmpty)
    }

    @MainActor
    func testResumePendingRemovalCompletesAfterCrash() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let server = ABSServer(name: "Test Server", url: "https://example.com", username: "tester")
        context.insert(server)
        context.insert(Book(
            title: "Remote Book", duration: 100,
            isRemote: true, serverId: server.id
        ))
        let journal = ServerRemovalJournalEntry(
            serverID: server.id,
            normalizedURL: server.normalizedURL,
            displayName: server.name,
            previousIsActive: true,
            phaseRaw: "prepared"
        )
        context.insert(journal)
        server.isActive = false
        try context.save()

        let service = ServerRemovalService(
            deleteToken: { _ in },
            persistFinalDeletion: { serverId, cont in
                try await MainActor.run {
                    let ctx = ModelContext(cont)
                    let descriptor = FetchDescriptor<ABSServer>(predicate: #Predicate { $0.id == serverId })
                    guard let srv = try ctx.fetch(descriptor).first else { return }
                    let books = try ctx.fetch(FetchDescriptor<Book>(
                        predicate: #Predicate { $0.serverId == serverId }
                    ))
                    for book in books {
                        try LibraryDeletionTransaction.stageBookDeletion(book, deviceID: nil, in: ctx)
                    }
                    let journalDescriptor = FetchDescriptor<ServerRemovalJournalEntry>(
                        predicate: #Predicate { $0.serverID == serverId }
                    )
                    for entry in try ctx.fetch(journalDescriptor) {
                        ctx.delete(entry)
                    }
                    ctx.delete(srv)
                    try ctx.save()
                }
            }
        )

        _ = service
        try await ServerRemovalService.resumePendingRemovals(container: container)

        let remainingServers = try ModelContext(container).fetch(FetchDescriptor<ABSServer>())
        XCTAssertTrue(remainingServers.isEmpty)

        let journals = try ModelContext(container).fetch(FetchDescriptor<ServerRemovalJournalEntry>())
        XCTAssertTrue(journals.isEmpty)

        let books = try ModelContext(container).fetch(FetchDescriptor<Book>())
        XCTAssertTrue(books.isEmpty)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}

private enum TestError: Error {
    case tokenDeletionFailed
    case persistenceFailed
}