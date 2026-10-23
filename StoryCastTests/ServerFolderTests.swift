import XCTest
import SwiftData
@testable import StoryCast

nonisolated final class ServerFolderTests: XCTestCase {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    @MainActor
    func testResolveServerFolderCreatesFolderWithServerIdAndReusesIt() throws {
        let context = try makeContext()
        let serverId = UUID()

        let first = try FolderService.resolveServerFolder(serverId: serverId, name: "Home", in: context)
        try context.save()
        let second = try FolderService.resolveServerFolder(serverId: serverId, name: "Renamed", in: context)

        XCTAssertEqual(first.id, serverId)
        XCTAssertEqual(first.name, "Home")
        XCTAssertFalse(first.isSystem)
        XCTAssertTrue(first === second)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).count, 1)
    }

    @MainActor
    func testResolveServerFolderAvoidsNameCollisionAndSortsAfterUserFolders() throws {
        let context = try makeContext()
        context.insert(Folder(name: "Home", isSystem: false, sortOrder: 4))
        try context.save()

        let folder = try FolderService.resolveServerFolder(serverId: UUID(), name: "Home", in: context)

        XCTAssertEqual(folder.name, "Home (2)")
        XCTAssertEqual(folder.sortOrder, 5)
    }

    @MainActor
    func testServerFolderIDsMatchConfiguredServers() throws {
        let context = try makeContext()
        let server = ABSServer(name: "Home", url: "https://example.com", username: "u")
        context.insert(server)
        try context.save()

        XCTAssertEqual(FolderService.serverFolderIDs(in: context), [server.id])
    }

    @MainActor
    func testServerRemovalDeletesServerFolderAndKeepsOtherFolders() async throws {
        let context = try makeContext()
        let server = ABSServer(name: "Home", url: "https://example.com", username: "u")
        context.insert(server)
        let folder = try FolderService.resolveServerFolder(serverId: server.id, name: "Home", in: context)
        context.insert(Book(title: "Remote", duration: 10, folder: folder, isRemote: true, serverId: server.id))
        let userFolder = Folder(name: "Mine", isSystem: false, sortOrder: 1)
        context.insert(userFolder)
        try context.save()

        let service = ServerRemovalService(deleteToken: { _ in })
        try await service.removeServer(server, modelContext: context)

        let remaining = try ModelContext(context.container).fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(remaining.map(\.name), ["Mine"])
        XCTAssertTrue(try ModelContext(context.container).fetch(FetchDescriptor<ABSServer>()).isEmpty)
    }
}
