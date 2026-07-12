import Foundation
import PKTestSupport
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Facade one-shot operations")
struct FacadeOneShotTests {
    @Test("complete assembles streamed text without persisting a timeline turn")
    func completeIsTimelineFree() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = Self.stream(contents: ["hel", "lo"])
        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            timelinePersistence: InMemoryTimelinePersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: persistence
        ))

        let result = try await kit.complete("hi")

        #expect(result == "hello")
        #expect(try await persistence.messageStore.fetchMessages(for: UUID()).isEmpty)
        #expect(try await persistence.timelinePersistence.fetchAllTimelines(includeArchived: true).isEmpty)
        #expect(try await persistence.workspacePersistence.fetchAllWorkspaces().isEmpty)
        #expect(try await persistence.toolPersistence.fetchTools(forWorkspaces: []).isEmpty)
        #expect(try await persistence.agentInstanceStore.fetchAllAgentInstances().isEmpty)
        #expect(try await persistence.requestOriginStore.fetchAllOrigins().isEmpty)
    }

    @Test("stream exposes provider events without persistence")
    func streamIsTimelineFree() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = Self.stream(contents: ["one", "two"])
        let messageStore = InMemoryMessageStore()
        let timelinePersistence = InMemoryTimelinePersistence()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: .init(
                messageStore: messageStore,
                timelinePersistence: timelinePersistence
            )
        ))

        let events = try await kit.stream("hi").collect()

        #expect(events.compactMap { $0.choices.first?.delta.content } == ["one", "two"])
        #expect(try await messageStore.fetchMessages(for: UUID()).isEmpty)
        #expect(try await timelinePersistence.fetchAllTimelines(includeArchived: true).isEmpty)
    }

    private static func stream(contents: [String]) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            for content in contents {
                continuation.yield(LLMStreamChunk(
                    id: "test",
                    model: "test",
                    choices: [LLMStreamChoice(index: 0, delta: LLMStreamDelta(content: content))]
                ))
            }
            continuation.finish()
        }
    }
}
