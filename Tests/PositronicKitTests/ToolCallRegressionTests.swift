import Foundation
import Testing
@testable import PositronicKit
@testable import PKShared
struct MockComplexTool: Tool, @unchecked Sendable {
    let id = "complex_tool"
    let name = "Complex Tool"
    let description = "A mock tool that accepts complex argument types"
    let requiresPermission = false

    var usageExample: String? { nil }

    var parametersSchema: [String: AnyCodable] { [:] }

    func canExecute() async -> Bool { true }

    func execute(parameters: [String: Any]) async throws -> ToolResult {
        // Verify we received the expected types
        guard let tags = parameters["tags"] as? [Any] else {
            return .failure("Expected 'tags' to be [Any], got \(type(of: parameters["tags"])) ")
        }

        guard let user = parameters["user"] as? [String: Any],
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

    @Test("StreamingCoordinator parses complex JSON arguments from native tool calls")
    func testComplexNativeToolCalls() async throws {
        let coordinator = StreamingCoordinator()
        coordinator.startStreaming()

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

        // Process chunks (wrapped in array as processToolCalls expects)
        coordinator.processToolCalls([chunk1])
        coordinator.processToolCalls([chunk2])
        coordinator.processToolCalls([chunk3])

        let message = coordinator.finalize()

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
             #expect(user["age"] as? Double == 30.0)
        } else {
             Issue.record("user argument is missing or not a dictionary")
        }
    }

    @Test("ToolExecutor correctly unwraps AnyCodable arguments")
    func testToolExecutorUnwrapping() async throws {
        // Setup tool manager with mock tool
        let mockTool = MockComplexTool()
        let toolManager = TimelineToolManager(availableTools: [AnyTool(mockTool)])
        let executor = ToolExecutor(toolManager: toolManager)

        // Create ToolCall with AnyCodable arguments
        // IMPORTANT: AnyCodable stores [Any], not [AnyCodable] for arrays if initialized with [Any]
        // But here we construct manually.

        let args: [String: AnyCodable] = [
            "tags": AnyCodable(["swift", "testing"]),
            "user": AnyCodable([
                "name": "Bob",
                "age": 25
            ] as [String: Any])
        ]

        let toolCall = ToolCall(name: "complex_tool", arguments: args)

        // Execute
        let resultMessage = await executor.execute(toolCall)

        // Verify success
        #expect(resultMessage.role == .tool)
        #expect(!resultMessage.content.starts(with: "Error"))
        #expect(!resultMessage.content.starts(with: "Failed"))
        #expect(resultMessage.content.contains("Received tags: swift, testing"))
        #expect(resultMessage.content.contains("User: Bob (25)"))
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
        #expect(nested?["val"] as? Double == 1.0)
    }
}
