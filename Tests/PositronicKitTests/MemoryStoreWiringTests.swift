import Foundation
import Logging
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for memory/embedding wiring.
///
/// The runtime previously dropped the injected `memoryStore` / `embeddingService`: the default
/// context pipeline always constructed `MemoryRetrievalStage()` with empty in-memory defaults, so
/// memories persisted through the facade were never retrieved during context gathering.
@Suite("Memory Store Wiring")
struct MemoryStoreWiringTests {
    private func completeContext(
        from events: [ContextGatheringEvent]
    ) -> ContextData? {
        events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first
    }

    @Test("ContextManager default pipeline honors the injected memory store")
    func defaultPipelineUsesInjectedMemoryStore() async throws {
        let memoryStore = MockMemoryStore()
        let embedding = MockEmbeddingService()
        let memory = Memory.fixture(title: "Wired Memory", content: "Important fact", tags: [])
        memoryStore.searchResults = [(memory, 0.95)]

        let contextManager = ContextManager(memoryStore: memoryStore, embeddingService: embedding)
        let events = try await contextManager.gatherContext(for: "any query").collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.memory.id == memory.id })
    }

    @Test("PositronicKitCore wires the injected memory store into timeline context gathering")
    func facadeWiresMemoryStoreIntoRAG() async throws {
        let workspace = TestWorkspace()
        let memoryStore = MockMemoryStore()
        let embedding = MockEmbeddingService()
        let memory = Memory.fixture(title: "Persisted Memory", content: "User prefers dark mode", tags: [])
        memoryStore.searchResults = [(memory, 0.92)]

        let persistence = PositronicKitCore.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            timelinePersistence: InMemoryTimelinePersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: memoryStore,
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let core = PositronicKitCore(
            llmService: UnconfiguredLLMService(),
            persistence: persistence,
            embeddingService: embedding,
            runtime: .init(workspaceRoot: workspace.root)
        )

        let timeline = try await core.timelineManager.createTimeline()
        let contextManager = try #require(await core.timelineManager.getContextManager(for: timeline.id))
        let events = try await contextManager.gatherContext(for: "what are my preferences?").collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.memory.id == memory.id })
    }
}
