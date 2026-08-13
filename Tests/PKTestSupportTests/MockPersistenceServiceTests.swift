import Foundation
import PKShared
import PKTestSupport
import PositronicKit
import Testing

@Suite("MockPersistenceService")
struct MockPersistenceServiceTests {
    @Test("resetDatabase clears agent instances")
    func resetDatabaseClearsAgentInstances() async throws {
        let persistence = MockPersistenceService()

        let instance = AgentInstance(
            name: "Test Agent",
            description: "A test agent",
            privateThreadID: UUID()
        )
        try await persistence.saveAgentInstance(instance)
        #expect(try await persistence.fetchAllAgentInstances().count == 1)

        try await persistence.resetDatabase()

        #expect(try await persistence.fetchAllAgentInstances().isEmpty)
    }

    @Test("resetDatabase clears the tool-associated workspace list, not just the primary workspace store")
    func resetDatabaseClearsToolsMockWorkspaces() async throws {
        let persistence = MockPersistenceService()

        let workspaceId = UUID()
        let workspace = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "test", path: "/tmp/test"),
            location: .runtime
        )
        try await persistence.saveWorkspace(workspace)
        try await persistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("echo"))

        // Sanity check: tools are visible via fetchWorkspace(includeTools: true) before reset.
        let before = try await persistence.fetchWorkspace(id: workspaceId, includeTools: true)
        #expect(before?.tools.isEmpty == false)

        try await persistence.resetDatabase()

        #expect(try await persistence.fetchAllWorkspaces().isEmpty)

        // After reset, saving a fresh workspace with the same id should not resurrect stale tools
        // from the internal toolsMock list mutated by the earlier saveWorkspace/addToolToWorkspace calls.
        let freshWorkspace = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "test", path: "/tmp/test"),
            location: .runtime
        )
        try await persistence.saveWorkspace(freshWorkspace)
        let after = try await persistence.fetchWorkspace(id: workspaceId, includeTools: true)
        #expect(after?.tools.isEmpty == true)
    }
}
