import Foundation
import Logging
@testable import MonadCore
import MonadShared
import MonadTestSupport
import OpenAI
import Testing

// MARK: - Helpers

private let testLogger = Logger(label: "test.pipeline")

private func makeContext(
    fullResponse: String = "",
    toolCallAccumulators: [Int: (id: String, name: String, args: String)] = [:],
    currentMessages: [ChatQuery.ChatCompletionMessageParam] = []
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
            currentMessages: [.user(.init(content: .string("query")))]
        )

        let events = try await drain(await stage.process(context))

        let completed = events.compactMap { $0.completedMessage }.first
        let data = try #require(completed?.metadata.turnSnapshotData)
        let snapshot = try SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
        #expect(snapshot.fullResponse == "done")
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
}
