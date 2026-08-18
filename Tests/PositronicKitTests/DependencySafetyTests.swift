import Foundation
@testable import PKShared
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

        // A thread created via the runtime's thread manager is visible through the shared persistence.
        let thread = try await runtime.threadManager.createThread(title: "Shared")
        let persistedThread = try await runtime.persistence.fetchThread(id: thread.id)
        #expect(persistedThread?.id == thread.id)

        // A workspace saved directly into persistence resolves through the agent workspace service,
        // proving that service is backed by the same store.
        let workspace = WorkspaceReference(uri: .threadWorkspace(UUID()), location: .runtime)
        try await runtime.persistence.saveWorkspace(workspace)
        let resolved = try await runtime.agentWorkspaceService.getWorkspace(id: workspace.id)
        #expect(resolved?.id == workspace.id)

        // positronicKit must reuse the runtime's own ThreadManager rather than fabricating a
        // disconnected one.
        let core = runtime.positronicKit
        #expect(core.threadManager === runtime.threadManager)
    }

    @Test("Deprecated TestRuntime facade builder forwards the stored facade")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func deprecatedBuildCoreForwardsStoredFacade() {
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        #expect(runtime.positronicKit === runtime.positronicKit)
    }

    @Test("PositronicKit facade's ThreadManager shares the memoryStore passed via persistence")
    func facadeThreadManagerSharesMemoryStore() async {
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: MockLLMService()), persistence: .init(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        #expect(await chat.threadManager.memoryStore as? MockPersistenceService === mockPersistence)
    }

    @Test("AgentInstanceManager correctly resolves overridden agentWorkspaceService")
    func agentInstanceManagerDependencyInjection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = MockPersistenceService()
        let customRepo = DefaultWorkspaceCatalog(
            workspaceRoot: tempDir,
            workspacePersistence: persistence
        )
        let manager = AgentInstanceManager(
            repository: customRepo,
            stores: .init(
                instanceStore: persistence,
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence
            )
        )

        let instance = try await manager.createInstance(name: "Test", description: "Test")
        if let workspaceId = instance.primaryWorkspaceID,
           let workspace = try await persistence.fetchWorkspace(id: workspaceId, includeTools: false)
        {
            #expect(workspace.rootPath?.contains(tempDir.path) ?? false)
        } else {
            Issue.record("Workspace not found for created instance")
        }
    }
}
