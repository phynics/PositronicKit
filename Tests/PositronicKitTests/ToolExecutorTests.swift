import Foundation
import PositronicKit
import PKShared
import Testing

struct ToolExecutorTests {
    /// Mock Tool for testing
    struct MockTool: PKShared.Tool {
        let id: String
        let name: String
        let description: String
        let requiresPermission: Bool = false
        let shouldFail: Bool

        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            if shouldFail {
                return .failure("Mock failure")
            }
            return .success("Executed \(id)")
        }
    }

    @Test("Test executing a single successful tool")
    func executeSuccess() async throws {
        let mockTool = MockTool(id: "test_tool", name: "Test", description: "Test", shouldFail: false)
        let manager = TimelineToolManager(availableTools: [AnyTool(mockTool)])
        let executor = ToolExecutor(toolManager: manager)

        let toolCall = ToolCall(name: "test_tool", arguments: [:])
        let resultMessage = try await executor.execute(toolCall)

        #expect(resultMessage.role == .tool)
        #expect(resultMessage.content == "Executed test_tool")
    }

    @Test("Test executing a failing tool")
    func executeFailure() async throws {
        let mockTool = MockTool(id: "fail_tool", name: "Fail", description: "Fail", shouldFail: true)
        let manager = TimelineToolManager(availableTools: [AnyTool(mockTool)])
        let executor = ToolExecutor(toolManager: manager)

        let toolCall = ToolCall(name: "fail_tool", arguments: [:])
        let resultMessage = try await executor.execute(toolCall)

        #expect(resultMessage.role == .tool)
        #expect(!resultMessage.content.contains("Executed")) // Not the success path
    }

    @Test("Test executing a non-existent tool")
    func executeUnknownTool() async throws {
        let manager = TimelineToolManager(availableTools: [])
        let executor = ToolExecutor(toolManager: manager)

        let toolCall = ToolCall(name: "unknown_tool", arguments: [:])

        let resultMessage = try await executor.execute(toolCall)

        #expect(resultMessage.role == .tool)
        #expect(!resultMessage.content.isEmpty)
    }

    @Test("Test executing multiple tools")
    func executeAll() async {
        let tool1 = MockTool(id: "tool_1", name: "T1", description: "T1", shouldFail: false)
        let tool2 = MockTool(id: "tool_2", name: "T2", description: "T2", shouldFail: false)
        let manager = TimelineToolManager(availableTools: [AnyTool(tool1), AnyTool(tool2)])
        let executor = ToolExecutor(toolManager: manager)

        let calls = [
            ToolCall(name: "tool_1", arguments: [:]),
            ToolCall(name: "tool_2", arguments: [:]),
        ]

        let results = await executor.executeAll(calls)

        #expect(results.count == 2)
        #expect(results[0].content == "Executed tool_1")
        #expect(results[1].content == "Executed tool_2")
    }
}
