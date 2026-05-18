import Foundation
import Logging
@testable import PositronicKit
import PKShared
import PKTestSupport
import Testing

// MARK: - Helpers

private let testLogger = Logger(label: "test.pipeline")

private func makeContext(
    fullResponse: String = "",
    toolCallAccumulators: [Int: (id: String, name: String, args: String)] = [:],
    currentMessages: [LLMMessage] = []
) async -> ChatTurnContext {
    let outputs = TurnOutputs()
    for chunk in fullResponse {
        await outputs.appendResponse(String(chunk))
    }
    for (index, acc) in toolCallAccumulators {
        await outputs.setToolCallAccumulator(index: index, id: acc.id, name: acc.name, args: acc.args)
    }

    return ChatTurnContext(
        timelineId: UUID(),
        agentInstanceId: nil,
        modelName: "test-model",
        maxTurns: 5,
        systemInstructions: nil,
        availableTools: [],
        contextData: ContextData(),
        remoteDepth: 0,
        currentMessages: currentMessages,
        turnCount: 1,
        outputs: outputs
    )
}

private func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func makeChunk(
    content: String? = nil,
    toolCalls: [LLMToolCallDelta]? = nil,
    finishReason: String? = nil
) -> LLMStreamChunk {
    LLMStreamChunk(
        id: "mock",
        model: "mock-model",
        choices: [LLMStreamChoice(
            index: 0,
            delta: LLMStreamDelta(role: .assistant, content: content, toolCalls: toolCalls),
            finishReason: finishReason
        )]
    )
}

private actor PipelineStageRunTracker {
    private(set) var didRun = false

    func markRan() {
        didRun = true
    }
}

private struct MarkerStage: PipelineStage {
    let tracker: PipelineStageRunTracker

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await tracker.markRan()
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor AggregatingPlugin: ChatTurnPlugin {
    private let suffix: String

    init(suffix: String) {
        self.suffix = suffix
    }

    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        [LLMMessage(role: .user, content: "\(turn.fullResponse)-\(suffix)")]
    }
}

// MARK: - MessagePersistenceStage Tests

final class MessagePersistenceStageBehavior {
    @Test
    func completedEventEmittedOnFinalTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(fullResponse: "Hello!")

        let events = try await drain(await stage.process(context))

        let completions = events.compactMap { $0.completedMessage }
        #expect(completions.count == 1)
        #expect(completions[0].message.content == "Hello!")
    }

    @Test
    func noCompletedEventOnToolCallTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(
            toolCallAccumulators: [0: (id: "call-1", name: "my_tool", args: "{}")]
        )

        let events = try await drain(await stage.process(context))

        let completions = events.compactMap { $0.completedMessage }
        #expect(completions.isEmpty)
    }

    @Test
    func turnSnapshotCapturesRenderedPromptOnFinalTurn() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(
            fullResponse: "done",
            currentMessages: [LLMMessage(role: .user, content: "query")]
        )

        let events = try await drain(await stage.process(context))

        let completed = events.compactMap { $0.completedMessage }.first
        let data = try #require(completed?.metadata.turnSnapshotData)
        let snapshot = try SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
        #expect(snapshot.fullResponse == "done")
    }

    @Test
    func persistedToolCallsPreserveAccumulatedArguments() async throws {
        let store = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: store, logger: testLogger)
        let context = await makeContext(
            toolCallAccumulators: [
                0: (
                    id: "call-1",
                    name: "complex_tool",
                    args: #"{"tags":["a","b"],"nested":{"value":1}}"#
                )
            ]
        )

        _ = try await drain(await stage.process(context))

        #expect(store.messages.count == 1)
        let message = store.messages[0].toMessage()
        #expect(message.toolCalls?.count == 1)
        let toolCall = try #require(message.toolCalls?.first)
        #expect(toolCall.name == "complex_tool")
        let tags = toolCall.arguments["tags"]?.value as? [Any]
        #expect(tags?.count == 2)
        let nested = toolCall.arguments["nested"]?.value as? [String: Any]
        #expect(nested?["value"] as? Double == 1.0)
    }
}

// MARK: - ChatTurnPipelineBuilder Tests

final class ChatTurnPipelineBuilderTests {
    @Test
    func additionalStagesAreAppendedToDefaultTurnPipeline() async throws {
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "pipeline"
        let tracker = PipelineStageRunTracker()

        let pipeline = ChatTurnPipelineBuilder.makePipeline(
            llmService: llm,
            messageStore: persistence,
            logger: testLogger,
            additionalStages: [MarkerStage(tracker: tracker)]
        )
        let context = await makeContext()

        _ = try await drain(pipeline.execute(context))

        #expect(await tracker.didRun)
        #expect(persistence.messages.last?.content == "pipeline")
    }
}

// MARK: - ChatTurnFollowUpPolicy Tests

final class ChatTurnFollowUpPolicyTests {
    @Test
    func pluginMessagesAggregateAcrossPlugins() async throws {
        let context = await makeContext()
        let messages = try await ChatTurnFollowUpPolicy.pluginMessages(
            for: context,
            turnCount: 2,
            accumulatedOutput: "reply",
            plugins: [AggregatingPlugin(suffix: "one"), AggregatingPlugin(suffix: "two")],
            logger: testLogger
        )

        #expect(messages.map(\.content) == ["reply-one", "reply-two"])
    }

    @Test
    func followUpContinuationRequiresMessagesAndRemainingTurns() {
        #expect(ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [LLMMessage(role: .user, content: "next")],
            turnCount: 1,
            maxTurns: 2
        ))

        #expect(!ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [],
            turnCount: 1,
            maxTurns: 2
        ))

        #expect(!ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
            [LLMMessage(role: .user, content: "next")],
            turnCount: 2,
            maxTurns: 2
        ))
    }
}

// MARK: - ToolCallExtractionStage Tests

final class ToolCallExtractionStageBehavior {
    @Test
    func sentinelCallsFiltered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let context = await makeContext()
        await context.outputs.setToolCallAccumulator(
            index: 0, id: "s1", name: ChatEngine.Constants.sentinelToolName, args: "{}"
        )
        await context.outputs.setToolCallAccumulator(index: 1, id: "r1", name: "real_tool", args: "{}")

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.count == 1)
        #expect(accumulators.values.first?.name == "real_tool")
    }

    @Test
    func emptyNameCallsFiltered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let context = await makeContext()
        await context.outputs.setToolCallAccumulator(index: 0, id: "e1", name: "", args: "{}")
        await context.outputs.setToolCallAccumulator(index: 1, id: "k1", name: "valid_tool", args: "{}")

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.count == 1)
        #expect(accumulators.values.first?.name == "valid_tool")
    }

    @Test
    func fallbackTextParsingTriggered() async throws {
        let stage = ToolCallExtractionStage(logger: testLogger)
        let context = await makeContext(
            fullResponse: #"<tool_call>{"name": "test_tool", "arguments": {"key": "val"}}</tool_call>"#
        )

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(!accumulators.isEmpty)
        #expect(accumulators.values.contains { $0.name == "test_tool" })
    }
}

// MARK: - LLMStreamingStage Tests

final class LLMStreamingStageBehavior {
    @Test
    func thinkingAndContentSeparated() async throws {
        let mockService = MockLLMService()
        mockService.mockClient.nextResponse = "<think>reasoning here</think>content here"
        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let thinking = events.compactMap { $0.thinkingContent }.joined()
        let content = events.compactMap { $0.textContent }.joined()
        #expect(thinking.contains("reasoning here"))
        #expect(content.contains("content here"))
        let fullThinking = await context.outputs.fullThinking
        let fullResponse = await context.outputs.fullResponse
        #expect(fullThinking.contains("reasoning here"))
        #expect(fullResponse.contains("content here"))
    }

    @Test
    func toolCallDeltasEmitted() async throws {
        let mockService = MockLLMService()
        mockService.mockClient.nextResponse = ""
        mockService.mockClient.nextToolCalls = [[
            MockToolCall(id: "tc-1", name: "my_tool", arguments: "{\"x\": 1}"),
        ]]
        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger)
        let context = await makeContext()

        let events = try await drain(await stage.process(context))

        let toolCallDeltas = events.filter {
            if case .delta(.toolCall) = $0 { return true }
            return false
        }
        #expect(!toolCallDeltas.isEmpty)
        let accumulators = await context.outputs.toolCallAccumulators
        #expect(!accumulators.isEmpty)
    }

    @Test
    func fragmentedToolCallDeltasAccumulateIntoSingleCall() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "complex_", arguments: "{\"tags\":[")
                )
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "\"a\",")
                )
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: nil, arguments: "\"b\"]}")
                )
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger)
        let context = await makeContext()

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        let call = try #require(accumulators[0])
        #expect(call.callId == "tc-1")
        #expect(call.name == "complex_tool")
        #expect(call.args == #"{"tags":["a","b"]}"#)
    }

    @Test
    func interleavedMultipleToolCallsPreservePerIndexState() async throws {
        let mockService = MockLLMService()
        mockService.stubbedStream = AsyncThrowingStream { continuation in
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 0,
                    id: "tc-1",
                    function: LLMToolCallDeltaFunction(name: "first_", arguments: "{\"x\":")
                ),
                LLMToolCallDelta(
                    index: 1,
                    id: "tc-2",
                    function: LLMToolCallDeltaFunction(name: "second_", arguments: "{\"y\":")
                ),
            ]))
            continuation.yield(makeChunk(toolCalls: [
                LLMToolCallDelta(
                    index: 1,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "2}")
                ),
                LLMToolCallDelta(
                    index: 0,
                    id: nil,
                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "1}")
                ),
            ], finishReason: "tool_calls"))
            continuation.finish()
        }

        let stage = LLMStreamingStage(llmService: mockService, logger: testLogger)
        let context = await makeContext()

        _ = try await drain(await stage.process(context))

        let accumulators = await context.outputs.toolCallAccumulators
        let first = try #require(accumulators[0])
        let second = try #require(accumulators[1])
        #expect(first.callId == "tc-1")
        #expect(first.name == "first_tool")
        #expect(first.args == #"{"x":1}"#)
        #expect(second.callId == "tc-2")
        #expect(second.name == "second_tool")
        #expect(second.args == #"{"y":2}"#)
    }
}
