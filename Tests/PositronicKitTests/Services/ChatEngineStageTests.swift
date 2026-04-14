import Foundation
import Logging
@testable import PositronicKit
import PKShared
import PKTestSupport
import OpenAI
import Testing

final class ChatEngineStageTests {
    private let logger = Logger(label: "test")

    @Test
    func toolExecutionStage_TextFallback() async throws {
        // Given
        let context = createTestContext()
        let toolCallText = #"<tool_call>{"name": "test_tool", "arguments": {"foo": "bar"}}</tool_call>"#
        await context.outputs.appendResponse(toolCallText)

        let stage = ToolCallExtractionStage(logger: logger)

        // When
        let stream = try await stage.process(context)
        for try await _ in stream {}

        // Then
        let accumulators = await context.outputs.toolCallAccumulators
        let debugToolCalls = await context.outputs.debugToolCalls
        #expect(accumulators.count == 1)
        #expect(accumulators[0]?.name == "test_tool")
        #expect(debugToolCalls.count == 1)
        #expect(debugToolCalls[0].name == "test_tool")
    }

    @Test
    func persistenceStage_SavesMessage() async throws {
        // Given
        let persistence = MockPersistenceService()
        _ = TimelineManager(workspaceRoot: URL(fileURLWithPath: "/tmp"))
        let stage = MessagePersistenceStage(messageStore: persistence, logger: logger)

        let context = createTestContext()
        await context.outputs.appendResponse("Hello world")

        // When
        let stream = try await stage.process(context)
        for try await _ in stream {}

        // Then
        #expect(persistence.messages.count == 1)
        #expect(persistence.messages[0].content == "Hello world")
    }

    // MARK: - Helpers

    private func createTestContext() -> ChatTurnContext {
        return ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 5,
            systemInstructions: nil,
            availableTools: [],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )
    }
}
