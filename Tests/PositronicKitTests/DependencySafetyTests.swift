import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Dependency Safety Tests")
struct DependencySafetyTests {
    @Test("TestRuntime shares one persistence across its managers, services, and core")
    func runtimeSharesPersistence() async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = TestRuntime(workspaceRoot: workspaceRoot)

        // A Thread created via the capability value is visible through the shared persistence.
        let thread = try await runtime.threads.create(title: "Shared")
        let persistedThread = try await runtime.persistence.fetchThread(id: thread.id)
        #expect(persistedThread?.id == thread.id)

        // A workspace saved directly into persistence resolves through the capability value,
        // proving that it is backed by the same store.
        let workspace = WorkspaceReference(uri: .threadWorkspace(UUID()), location: .runtime)
        try await runtime.persistence.saveWorkspace(workspace)
        let resolved = try await runtime.workspaces.get(workspace.id)
        #expect(resolved?.id == workspace.id)

        #expect(try await runtime.threads.get(thread.id)?.id == thread.id)
    }

    @Test("AgentManager correctly resolves overridden agentWorkspaceService")
    func agentManagerDependencyInjection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = MockPersistenceService()
        let customRepo = DefaultWorkspaceCatalog(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )
        let manager = AgentManager(
            repository: customRepo,
            stores: .init(
                agentStore: persistence,
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence
            )
        )

        let instance = try await manager.createAgent(name: "Test", description: "Test")
        if let workspaceId = instance.primaryWorkspaceID,
           let workspace = try await persistence.fetchWorkspace(id: workspaceId, includeTools: false)
        {
            #expect(workspace.rootPath?.contains(tempDir.path) ?? false)
        } else {
            Issue.record("Workspace not found for created instance")
        }
    }
}
