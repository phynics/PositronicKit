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

        // A timeline created via the runtime's timeline manager is visible through the shared persistence.
        let timeline = try await runtime.timelineManager.createTimeline(title: "Shared")
        let persistedTimeline = try await runtime.persistence.fetchTimeline(id: timeline.id)
        #expect(persistedTimeline?.id == timeline.id)

        // A workspace saved directly into persistence resolves through the agent workspace service,
        // proving that service is backed by the same store.
        let workspace = WorkspaceReference(uri: .timelineWorkspace(UUID()), location: .runtime)
        try await runtime.persistence.saveWorkspace(workspace)
        let resolved = try await runtime.agentWorkspaceService.getWorkspace(id: workspace.id)
        #expect(resolved?.id == workspace.id)

        // positronicKit must reuse the runtime's own TimelineManager rather than fabricating a
        // disconnected one.
        let core = runtime.positronicKit
        #expect(core.timelineManager === runtime.timelineManager)
    }

    @Test("Deprecated TestRuntime facade builder forwards the stored facade")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func deprecatedBuildCoreForwardsStoredFacade() {
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        #expect(runtime.buildCore() === runtime.positronicKit)
    }

    @Test("PositronicKit facade's TimelineManager shares the memoryStore passed via persistence")
    func facadeTimelineManagerSharesMemoryStore() async {
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: MockLLMService()), persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        #expect(await chat.timelineManager.memoryStore as? MockPersistenceService === mockPersistence)
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
                timelineStore: persistence,
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
