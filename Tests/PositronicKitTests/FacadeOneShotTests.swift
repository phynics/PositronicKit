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

    @Test("one-shot result forwards parameters and exposes terminal metadata")
    func oneShotResultForwardsParametersAndMetadata() async throws {
        let llm = MockLLMService()
        let usage = LLMTokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5)
        llm.mockClient.nextRawStreamChunks = [[
            LLMStreamChunk(
                id: "response-1",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "hello"),
                    finishReason: "stop"
                )],
                usage: usage
            )
        ]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence()
            )
        ))
        let parameters = GenerationParameters(temperature: 0.2, maxTokens: 12)

        let result = try await kit.completeResult("hi", generationParameters: parameters)

        #expect(result.content == "hello")
        #expect(result.finishReason == "stop")
        #expect(result.usage == usage)
        #expect(result.id == "response-1")
        #expect(result.model == "test-model")
        #expect(llm.mockClient.lastParameters == parameters)
    }

    @Test("one-shot idle timeout terminates a stalled stream")
    func oneShotIdleTimeout() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { _ in }
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence()
            )
        ))

        do {
            _ = try await kit.completeResult("hi", idleTimeout: 0.01)
            Issue.record("Expected the stalled one-shot stream to time out")
        } catch let error as ChatEngineError {
            guard case let .streamTimedOut(timeout) = error else {
                Issue.record("Expected stream timeout, got \(error)")
                return
            }
            #expect(timeout == 0.01)
        }
    }

    @Test("one-shot cancellation terminates promptly")
    func oneShotCancellation() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { _ in }
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence()
            )
        ))
        let task = Task {
            try await kit.completeResult("hi", idleTimeout: 60)
        }

        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected one-shot cancellation to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("complete(_:structuredOutput:) passes the request through to the language model")
    func completeStructuredOutputPassesRequestThrough() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[#"{"tags":["swift"]}"#]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)

        #expect(llm.mockClient.lastResponseFormat == .jsonObject)
        #expect(llm.mockClient.lastMessages == [LLMMessage(role: .user, content: "extract tags")])
    }

    @Test("complete(_:structuredOutput:) assembles the JSON payload from content deltas")
    func completeStructuredOutputAssemblesContentDeltaPayload() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[#"{"tags":["#, #""swift"]}"#]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        let result = try await kit.complete("extract tags", structuredOutput: .jsonObject)

        #expect(result == #"{"tags":["swift"]}"#)
    }

    @Test("complete(_:structuredOutput:) assembles the JSON payload from a synthetic tool call")
    func completeStructuredOutputAssemblesSyntheticToolCallPayload() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .anthropic))
        llm.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: "{" + #""tags":["#)
            ]),
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: #""swift"]}"#)
            ]),
        ]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        let result = try await kit.complete(
            "extract tags",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        #expect(result == #"{"tags":["swift"]}"#)
        let decoded = try StructuredOutputDecoder.decode([String: [String]].self, from: result)
        #expect(decoded["tags"] == ["swift"])
    }

    @Test("complete(_:structuredOutput:) rejects an empty successful stream")
    func completeStructuredOutputRejectsEmptyStream() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence()
            )
        ))

        do {
            _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)
            Issue.record("Expected an empty structured response to throw")
        } catch let error as LLMServiceError {
            #expect(error == .emptyResponse(provider: LLMProvider.openAICompatible.rawValue))
        }
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
