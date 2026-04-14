import Foundation
@testable import PositronicKit
@testable import PKShared
import Testing

@MainActor
struct LoopDetectionTests {
    struct MockTool: PKShared.Tool, @unchecked Sendable {
        let id = "mock_tool"
        let name = "Mock Tool"
        let description = "A mock tool"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            return .success("Executed")
        }
    }

    @Test("Test loop detection triggers after 3 identical calls")
    func loopDetection() async {
        let tool = MockTool()
        let toolManager = TimelineToolManager(availableTools: [AnyTool(tool)])
        let executor = ToolExecutor(toolManager: toolManager)

        let toolCall = ToolCall(name: "mock_tool", arguments: ["arg": AnyCodable(1)])

        // Call 1
        let res1 = await executor.execute(toolCall)
        #expect(res1.content == "Executed")

        // Call 2
        let res2 = await executor.execute(toolCall)
        #expect(res2.content == "Executed")

        // Call 3 - should trigger loop detection
        let res3 = await executor.execute(toolCall)
        #expect(res3.content != "Executed") // Not the normal success output
        #expect(res3.role == .tool)
    }

    @Test("Test loop detection reset")
    func loopDetectionReset() async {
        let tool = MockTool()
        let toolManager = TimelineToolManager(availableTools: [AnyTool(tool)])
        let executor = ToolExecutor(toolManager: toolManager)

        let toolCall = ToolCall(name: "mock_tool", arguments: ["arg": AnyCodable(1)])

        _ = await executor.execute(toolCall)
        _ = await executor.execute(toolCall)

        await executor.reset()

        // Call after reset should be successful
        let res = await executor.execute(toolCall)
        #expect(res.content == "Executed")
    }

    @Test("Test different arguments do not trigger loop detection")
    func differentArgs() async {
        let tool = MockTool()
        let toolManager = TimelineToolManager(availableTools: [AnyTool(tool)])
        let executor = ToolExecutor(toolManager: toolManager)

        for i in 1 ... 5 {
            let toolCall = ToolCall(name: "mock_tool", arguments: ["arg": AnyCodable(i)])
            let res = await executor.execute(toolCall)
            #expect(res.content == "Executed")
        }
    }
}
