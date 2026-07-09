import Foundation
import Logging
import OpenAI
import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

final class ChatEngineStageTests {
    private let logger = Logger(label: "test")

    struct StubTool: PKShared.Tool, @unchecked Sendable {
        let id = "stub_tool"
        let name = "stub_tool"
        let description = "Stub for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()
        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("ok")
        }
    }

    @Test("Fallback text parsing fires when tools are available")
    func toolExecutionStage_TextFallback() async throws {
        // Given — a tool is registered so fallback is permitted
        let context = createTestContext(availableTools: [StubTool().toAnyTool()])
        let toolCallText = #"<tool_call>{"name": "stub_tool", "arguments": {"foo": "bar"}}</tool_call>"#
        await context.outputs.appendResponse(toolCallText)

        let stage = ToolCallExtractionStage(logger: logger)

        // When
        let stream = try await stage.process(context)
        for try await _ in stream {}

        // Then
        let accumulators = await context.outputs.toolCallAccumulators
        let debugToolCalls = await context.outputs.debugToolCalls
        #expect(accumulators.count == 1)
        #expect(accumulators[0]?.name == "stub_tool")
        #expect(debugToolCalls.count == 1)
        #expect(debugToolCalls[0].name == "stub_tool")
    }

    @Test("Fallback text parsing is skipped when no tools are offered")
    func toolCallExtractionStage_SkipsFallback_WhenNoTools() async throws {
        // Given — no tools offered; any <tool_call> text should be ignored
        let context = createTestContext(availableTools: [])
        let toolCallText = #"<tool_call>{"name": "stub_tool", "arguments": {}}</tool_call>"#
        await context.outputs.appendResponse(toolCallText)

        let stage = ToolCallExtractionStage(logger: logger)

        // When
        let stream = try await stage.process(context)
        for try await _ in stream {}

        // Then — fallback must not produce any tool call accumulators
        let accumulators = await context.outputs.toolCallAccumulators
        let debugToolCalls = await context.outputs.debugToolCalls
        #expect(accumulators.isEmpty)
        #expect(debugToolCalls.isEmpty)
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

    private func createTestContext(availableTools: [AnyTool] = []) -> ChatTurnContext {
        return ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 5,
            systemInstructions: nil,
            availableTools: availableTools,
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )
    }
}
