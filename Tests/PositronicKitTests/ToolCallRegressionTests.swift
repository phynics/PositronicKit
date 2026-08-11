import Foundation
import Logging
import Testing
@testable import PositronicKit
@testable import PKShared
import PKUtilities
import PKTestSupport
struct MockComplexTool: Tool, @unchecked Sendable {
    let callName = "complex_tool"
    let name = "Complex Tool"
    let description = "A mock tool that accepts complex argument types"
    let requiresPermission = false

    var usageExample: String? { nil }

    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        // Verify we received the expected types
        guard let tags = parameters["tags"]?.value as? [Any] else {
            return .failure("Expected 'tags' to be [Any], got \(type(of: parameters["tags"])) ")
        }

        guard let user = parameters["user"]?.value as? [String: Any],
              let name = user["name"] as? String,
              let ageValue = user["age"] else {
            return .failure("Expected 'user' dictionary with name/age")
        }

        let age: Int
        if let a = ageValue as? Int { age = a } else if let d = ageValue as? Double { age = Int(d) } else { return .failure("Age is not a number") }

        return .success("Received tags: \(tags.compactMap { $0 as? String }.joined(separator: ", ")), User: \(name) (\(age))")
    }
}

@Suite("Tool Call Regression Tests")
@MainActor
struct ToolCallRegressionTests {
    private let logger = Logger(label: "test.tool-call-regression")

    @Test("TurnOutputs accumulates complex JSON arguments from native tool call deltas")
    func testAccumulatesComplexNativeToolCallDeltas() async throws {
        let persistence = MockPersistenceService()
        let stage = MessagePersistenceStage(messageStore: persistence, logger: logger)
        let context = ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 1,
            systemInstructions: nil,
            availableTools: [],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )

        // Chunk 1: Tool call start
        let chunk1 = ToolCallDelta(
            index: 0,
            id: "call_123",
            name: "complex_tool",
            arguments: ""
        )

        // Chunk 2: Arguments part 1
        let chunk2 = ToolCallDelta(
            index: 0,
            id: nil,
            name: nil,
            arguments: "{\"tags\": [\"tag1\", \"tag2\"], "
        )

        // Chunk 3: Arguments part 2
        let chunk3 = ToolCallDelta(
            index: 0,
            id: nil,
            name: nil,
            arguments: "\"user\": {\"name\": \"Alice\", \"age\": 30}}"
        )

        await context.outputs.accumulateToolCall(
            index: chunk1.index,
            id: chunk1.id,
            name: chunk1.name,
            args: chunk1.arguments
        )
        await context.outputs.accumulateToolCall(
            index: chunk2.index,
            id: chunk2.id,
            name: chunk2.name,
            args: chunk2.arguments
        )
        await context.outputs.accumulateToolCall(
            index: chunk3.index,
            id: chunk3.id,
            name: chunk3.name,
            args: chunk3.arguments
        )

        let stream = try await stage.process(context)
        for try await _ in stream {}

        #expect(persistence.messages.count == 1)
        let message = persistence.messages[0].toMessage()

        #expect(message.toolCalls?.count == 1)
        let toolCall = message.toolCalls?.first
        #expect(toolCall?.name == "complex_tool")

        let args = toolCall?.arguments
        #expect(args != nil)

        // Verify AnyCodable wrapping
        if let tagsAny = args?["tags"]?.value as? [Any] {
             #expect(tagsAny.count == 2)
             #expect(tagsAny[0] as? String == "tag1")
             #expect(tagsAny[1] as? String == "tag2")
        } else {
             Issue.record("tags argument is missing or not an array")
        }

        if let user = args?["user"]?.value as? [String: Any] {
             #expect(user["name"] as? String == "Alice")
             let age = user["age"]
             #expect((age as? Int64) == 30 || (age as? UInt64) == 30)
        } else {
             Issue.record("user argument is missing or not a dictionary")
        }
    }

    @Test("StreamingParser extracts XML tool calls with complex JSON")
    func testXMLToolParsing() throws {
        let parser = StreamingParser()
        let xmlInput = """
        Thinking...
        <tool_call>
        {"name": "complex_tool", "arguments": {"tags": ["a", "b"], "nested": {"val": 1}}}
        </tool_call>
        """

        let (cleanText, toolCalls) = parser.extractToolCalls(from: xmlInput)

        #expect(cleanText.trimmingCharacters(in: .whitespacesAndNewlines) == "Thinking...")
        #expect(toolCalls.count == 1)

        let toolCall = toolCalls.first
        #expect(toolCall?.name == "complex_tool")

        let args = toolCall?.arguments
        let tags = args?["tags"]?.value as? [Any]
        #expect(tags?.count == 2)
        #expect(tags?[0] as? String == "a")

        let nested = args?["nested"]?.value as? [String: Any]
        let value = nested?["val"]
        #expect((value as? Int64) == 1 || (value as? UInt64) == 1)
    }

    @Test("Legacy XML tool-call markers in assistant text do not produce tool accumulators")
    func legacyXMLMarkersProduceNoToolCalls() async throws {
        let context = ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 1,
            systemInstructions: nil,
            availableTools: [MockComplexTool().toAnyTool()],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )

        await context.outputs.appendResponse(
            #"Let me search. {"name": "complex_tool", "arguments": {"tags": ["a"]}} "#
        )

        let stage = ToolCallExtractionStage(logger: logger)
        let stream = try await stage.process(context)
        for try await _ in stream {}

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.isEmpty)
    }

    @Test("Pipe-delimited tool-call markers in assistant text do not produce tool accumulators")
    func pipeMarkersProduceNoToolCalls() async throws {
        let context = ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 1,
            systemInstructions: nil,
            availableTools: [MockComplexTool().toAnyTool()],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )

        await context.outputs.appendResponse(
            "<|tool_call_begin|>functions.complex_tool<|tool_call_argument_begin|>{\"tags\": [\"a\"]}<|tool_call_end|>"
        )

        let stage = ToolCallExtractionStage(logger: logger)
        let stream = try await stage.process(context)
        for try await _ in stream {}

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.isEmpty)
    }

    @Test("Fenced JSON in assistant text does not produce tool accumulators")
    func fencedJSONProducesNoToolCalls() async throws {
        let context = ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 1,
            systemInstructions: nil,
            availableTools: [MockComplexTool().toAnyTool()],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [],
            turnCount: 1,
            outputs: TurnOutputs()
        )

        await context.outputs.appendResponse(
            "```json\n{\"name\":\"complex_tool\",\"arguments\":{\"tags\":[\"a\",\"b\"]}}\n```"
        )

        let stage = ToolCallExtractionStage(logger: logger)
        let stream = try await stage.process(context)
        for try await _ in stream {}

        let accumulators = await context.outputs.toolCallAccumulators
        #expect(accumulators.isEmpty)
    }
}
