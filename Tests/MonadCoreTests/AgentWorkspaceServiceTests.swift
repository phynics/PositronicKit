import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite("AgentWorkspaceService Tests")
struct AgentWorkspaceServiceTests {
    @Test("Create Workspace")
    func testCreateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = try await TestDependencies()
            .withMocks(persistence: persistence)
            .run {
                AgentWorkspaceService(workspaceRoot: FileManager.default.temporaryDirectory)
            }

        let uri = WorkspaceURI(host: "monad-server", path: "/test")
        let metadata: [String: AnyCodable] = ["key": .string("value")]

        let ws = try await repository.createWorkspace(
            uri: uri,
            hostType: .server,
            rootPath: "/tmp/ws",
            metadata: metadata
        )

        #expect(ws.uri == uri)
        #expect(ws.rootPath == "/tmp/ws")
        #expect(ws.metadata["key"]?.asString == "value")

        // Verify it was saved to persistence
        let saved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(saved != nil)
        #expect(saved?.metadata["key"]?.asString == "value")
    }

    @Test("Get Workspace")
    func testGetWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = try await TestDependencies()
            .withMocks(persistence: persistence)
            .run {
                AgentWorkspaceService(workspaceRoot: FileManager.default.temporaryDirectory)
            }

        let ws = WorkspaceReference(
            uri: .serverTimeline(UUID()),
            hostType: .server,
            rootPath: "/path",
            metadata: ["test": .boolean(true)]
        )
        try await persistence.saveWorkspace(ws)

        let retrieved = try await repository.getWorkspace(id: ws.id)
        #expect(retrieved != nil)
        #expect(retrieved?.id == ws.id)
        #expect(retrieved?.metadata["test"]?.value as? Bool == true)
    }

    @Test("List Workspaces")
    func testListWorkspaces() async throws {
        let persistence = MockPersistenceService()
        let repository = try await TestDependencies()
            .withMocks(persistence: persistence)
            .run {
                AgentWorkspaceService(workspaceRoot: FileManager.default.temporaryDirectory)
            }

        let ws1 = WorkspaceReference(uri: .serverTimeline(UUID()), hostType: .server)
        let ws2 = WorkspaceReference(uri: .serverTimeline(UUID()), hostType: .server)
        try await persistence.saveWorkspace(ws1)
        try await persistence.saveWorkspace(ws2)

        let list = try await repository.listWorkspaces()
        #expect(list.count == 2)
        #expect(list.contains(where: { $0.id == ws1.id }))
        #expect(list.contains(where: { $0.id == ws2.id }))
    }

    @Test("Delete Workspace")
    func testDeleteWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = try await TestDependencies()
            .withMocks(persistence: persistence)
            .run {
                AgentWorkspaceService(workspaceRoot: FileManager.default.temporaryDirectory)
            }

        let ws = WorkspaceReference(uri: .serverTimeline(UUID()), hostType: .server)
        try await persistence.saveWorkspace(ws)

        try await repository.deleteWorkspace(id: ws.id)
        let retrieved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(retrieved == nil)
    }

    @Test("Update Workspace")
    func testUpdateWorkspace() async throws {
        let persistence = MockPersistenceService()
        let repository = try await TestDependencies()
            .withMocks(persistence: persistence)
            .run {
                AgentWorkspaceService(workspaceRoot: FileManager.default.temporaryDirectory)
            }

        var ws = WorkspaceReference(uri: .serverTimeline(UUID()), hostType: .server)
        try await persistence.saveWorkspace(ws)

        ws.status = .missing
        try await repository.updateWorkspace(ws)

        let retrieved = try await persistence.fetchWorkspace(id: ws.id)
        #expect(retrieved?.status == .missing)
    }
}
