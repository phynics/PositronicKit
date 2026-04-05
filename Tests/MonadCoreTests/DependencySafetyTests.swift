import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite("Dependency Safety Tests")
struct DependencySafetyTests {
    @Test("AgentInstanceManager correctly resolves overridden agentWorkspaceService")
    func agentInstanceManagerDependencyInjection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let customRepo = AgentWorkspaceService(workspaceRoot: tempDir)
        let persistence = MockPersistenceService()

        try await TestDependencies()
            .withMocks(persistence: persistence)
            .with { $0.agentWorkspaceService = customRepo }
            .with { $0.agentInstanceManager = AgentInstanceManager(repository: customRepo) }
            .run {
                @Dependency(\.agentInstanceManager) var manager

                let instance = try await manager.createInstance(name: "Test", description: "Test")

                @Dependency(\.workspacePersistence) var workspaceStore
                if let workspaceId = instance.primaryWorkspaceId,
                   let workspace = try await workspaceStore.fetchWorkspace(id: workspaceId, includeTools: false) {
                    #expect(workspace.rootPath?.contains(tempDir.path) ?? false)
                } else {
                    Issue.record("Workspace not found for created instance")
                }
            }
    }
}
