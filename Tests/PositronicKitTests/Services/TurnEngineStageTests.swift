import Foundation
import Logging
import OpenAI
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

final class TurnEngineStageTests {
    private let logger = Logger(label: "test")

    struct StubTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "stub_tool"
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

    @Test("Raw-text tool calls do not produce accumulators even when tools are available")
    func toolExecutionStage_TextFallback() async throws {
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
        #expect(accumulators.isEmpty)
        #expect(debugToolCalls.isEmpty)
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
        _ = ThreadManager(workspaceRoot: URL(fileURLWithPath: "/tmp"))
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

    private func createTestContext(availableTools: [AnyTool] = []) -> TurnContext {
        return TurnContext(
            threadID: UUID(),
            agentId: nil,
            modelName: "test-model",
            maxModelRounds: 5,
            systemInstructions: nil,
            availableTools: availableTools,
            remoteDepth: 0,
            currentMessages: [],
            modelRoundIndex: 1,
            outputs: TurnOutputs()
        )
    }
}
