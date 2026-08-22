import Foundation
import Logging
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for memory store wiring.
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
        let memory = Memory.fixture(title: "Wired Memory", content: "Important fact", tags: ["swift"])
        memoryStore.memories = [memory]

        let turnBriefingBuilder = TurnBriefingBuilder(memoryStore: memoryStore)
        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in ["swift"] }
        let events = try await turnBriefingBuilder.gatherContext(for: "any query", tagGenerator: tagGenerator).collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.id == memory.id })
    }

    @Test("TurnBriefingBuilder default pipeline short-circuits empty memory corpora")
    func defaultPipelineShortCircuitsEmptyMemoryCorpus() async throws {
        let memoryStore = MockMemoryStore()
        let turnBriefingBuilder = TurnBriefingBuilder(memoryStore: memoryStore)
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
        #expect(context.memories.isEmpty)
    }

    @Test("PositronicKit wires the injected memory store into thread context gathering")
    func facadeWiresMemoryStoreIntoRAG() async throws {
        let workspace = TestWorkspace()
        let memoryStore = MockMemoryStore()
        let memory = Memory.fixture(title: "Persisted Memory", content: "User prefers dark mode", tags: ["mode"])
        memoryStore.memories = [memory]

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            threadPersistence: InMemoryThreadPersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: memoryStore,
            toolPersistence: InMemoryToolPersistence(),
            agentStore: InMemoryAgentStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let core = PositronicKit(configuration: .init(provider: .init(languageModel: UnconfiguredLLMService()), persistence: persistence, runtime: .init(workspaceRoot: workspace.root)))

        let thread = try await core.threadManager.createThread()
        let turnBriefingBuilder = try #require(await core.threadManager.getTurnBriefingBuilder(for: thread.id))
        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in ["mode"] }
        let events = try await turnBriefingBuilder.gatherContext(for: "what are my preferences?", tagGenerator: tagGenerator).collect()

        let context = try #require(completeContext(from: events))
        #expect(context.memories.contains { $0.id == memory.id })
    }
}

private actor TagProbe {
    private(set) var calls = 0

    func recordCall() {
        calls += 1
    }
}
