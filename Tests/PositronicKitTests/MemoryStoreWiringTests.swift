import Foundation
import Logging
@testable import PKShared
import PKUtilities
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

    private func progressSequence(from events: [ContextGatheringEvent]) -> [Message.ContextGatheringProgress] {
        events.compactMap { event in
            if case let .progress(progress) = event { return progress }
            return nil
        }
    }

    @Test("TurnBriefingBuilder default pipeline honors the injected memory store")
    func defaultPipelineUsesInjectedMemoryStore() async throws {
        let memoryStore = MockMemoryStore()
        let embedding = MockEmbeddingService()
        let memory = Memory.fixture(title: "Wired Memory", content: "Important fact", tags: [])
        memoryStore.searchResults = [(memory, 0.95)]

        let turnBriefingBuilder = TurnBriefingBuilder(memoryStore: memoryStore, embeddingService: embedding)
        let events = try await turnBriefingBuilder.gatherContext(for: "any query").collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.memory.id == memory.id })
        #expect(embedding.lastInput == "any query")
    }

    @Test("TurnBriefingBuilder default pipeline short-circuits empty memory corpora")
    func defaultPipelineShortCircuitsEmptyMemoryCorpus() async throws {
        let memoryStore = MockMemoryStore()
        let embedding = MockEmbeddingService()
        let turnBriefingBuilder = TurnBriefingBuilder(memoryStore: memoryStore, embeddingService: embedding)
        let tagProbe = TagProbe()
        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in
            await tagProbe.recordCall()
            return ["unexpected"]
        }

        let events = try await turnBriefingBuilder.gatherContext(
            for: "any query",
            tagGenerator: tagGenerator
        ).collect()

        let context = try #require(completeContext(from: events))
        #expect(progressSequence(from: events) == [.augmenting, .discoveringNotes, .complete])
        #expect(await tagProbe.calls == 0)
        #expect(embedding.lastInput == nil)
        #expect(context.memories.isEmpty)
        #expect(context.executionTime < 0.5)
    }

    @Test("PositronicKit wires the injected memory store into timeline context gathering")
    func facadeWiresMemoryStoreIntoRAG() async throws {
        let workspace = TestWorkspace()
        let memoryStore = MockMemoryStore()
        let embedding = MockEmbeddingService()
        let memory = Memory.fixture(title: "Persisted Memory", content: "User prefers dark mode", tags: [])
        memoryStore.searchResults = [(memory, 0.92)]

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            timelinePersistence: InMemoryTimelinePersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: memoryStore,
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let core = PositronicKit(configuration: .init(provider: .init(languageModel: UnconfiguredLLMService(), embeddingService: embedding), persistence: persistence, runtime: .init(workspaceRoot: workspace.root)))

        let timeline = try await core.timelineManager.createTimeline()
        let turnBriefingBuilder = try #require(await core.timelineManager.getTurnBriefingBuilder(for: timeline.id))
        let events = try await turnBriefingBuilder.gatherContext(for: "what are my preferences?").collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.memory.id == memory.id })
    }
}

private actor TagProbe {
    private(set) var calls = 0

    func recordCall() {
        calls += 1
    }
}
