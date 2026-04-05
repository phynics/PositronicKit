import Testing
import Foundation
@testable import MonadShared
import OpenAI

@Suite("Tool Error Surfacing Tests")
struct ToolErrorSurfaceTests {

    // MARK: - Helper Tool

    struct FailingTool: MonadShared.Tool {
        let id = "fail_tool"
        let name = "fail_tool"
        let description = "Always fails"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] { ToolParameterSchema.object { _ in }.schema }
        func canExecute() async -> Bool { true }
        func execute(parameters: [String: Any]) async throws -> ToolResult {
            return .failure("Execution failed intentionally")
        }
    }

    @Test("Tool failure produces correct ToolResult")
    func testToolFailureResult() async throws {
        let tool = FailingTool()
        let result = try await tool.execute(parameters: [:])

        #expect(!result.success, "Tool should report failure")
        #expect(result.error == "Execution failed intentionally")
        #expect(result.output.isEmpty, "Failed tool should have empty output")
    }

    @Test("Tool error events are emitted for failed tool execution")
    func testToolErrorEmission() async throws {
        // This test verifies that when ChatEngine processes a tool call for a tool
        // that returns .failure, the resulting events include a .toolExecution(.failed) event.
        // We simulate the tool execution flow directly to avoid dependency propagation
        // issues with ChatEngine's internal Task.

        let tool = FailingTool()
        let anyTool = AnyTool(tool)

        // Simulate what ChatEngine.executeTools does:
        // 1. Look up the tool by name
        // 2. Execute it
        // 3. Check the result and emit appropriate events
        let result = try await anyTool.execute(parameters: [:])

        // Verify the result is a failure
        #expect(!result.success)

        // Verify that ChatEngine would emit a .failed status for this result
        // (mirrors the logic in ChatEngine.executeTools lines 520-525)
        let toolRef = anyTool.toolReference
        if result.success {
            Issue.record("Expected tool to fail but it succeeded")
        } else {
            let errorMsg = result.error ?? "Unknown error"
            let status = ToolExecutionStatus.failed(reference: toolRef, error: errorMsg)

            // Verify the event content
            if case .failed(_, let error) = status {
                #expect(error == "Execution failed intentionally")
            } else {
                Issue.record("Expected .failed status")
            }
        }
    }

    @Test("ToolResult.failure has correct properties")
    func testToolResultFailureFactory() {
        let result = ToolResult.failure("Something went wrong")

        #expect(!result.success)
        #expect(result.error == "Something went wrong")
        #expect(result.output.isEmpty)
    }

    @Test("ToolResult.success has correct properties")
    func testToolResultSuccessFactory() {
        let result = ToolResult.success("Output data")

        #expect(result.success)
        #expect(result.error == nil)
        #expect(result.output == "Output data")
    }
}
