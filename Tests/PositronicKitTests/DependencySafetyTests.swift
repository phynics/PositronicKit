import Dependencies
import Foundation
@testable import PositronicKit
@testable import PKShared
import PKTestSupport
import Testing

@Suite("Dependency Safety Tests")
struct DependencySafetyTests {
    @Test("AgentInstanceManager correctly resolves overridden agentWorkspaceService")
    func agentInstanceManagerDependencyInjection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = MockPersistenceService()
        let customRepo = AgentWorkspaceService(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )
        let manager = AgentInstanceManager(
            repository: customRepo,
            stores: .init(
                instanceStore: persistence,
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence
            )
        )

        let instance = try await manager.createInstance(name: "Test", description: "Test")
        if let workspaceId = instance.primaryWorkspaceId,
           let workspace = try await persistence.fetchWorkspace(id: workspaceId, includeTools: false) {
            #expect(workspace.rootPath?.contains(tempDir.path) ?? false)
        } else {
            Issue.record("Workspace not found for created instance")
        }
    }
}
