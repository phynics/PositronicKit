import Foundation
import OpenAI
import Testing
@testable import MonadShared

@Suite struct ToolSerializationTests {

    struct ComplexMockTool: MonadShared.Tool {
        let id = "complex_tool"
        let name = "Complex Tool"
        let description = "A tool with nested parameters"
        let requiresPermission = false

        var parametersSchema: [String: AnyCodable] {
            ToolParameterSchema.object { b in
                b.string("query", description: "Search query")
                b.integer("count", description: "number of items")
                b.boolean("recursive", description: "Whether to search recursively")
            }.schema
        }

        func canExecute() async -> Bool { true }
        func execute(parameters: [String: Any]) async throws -> ToolResult {
            .success("Executed")
        }
    }

    @Test("Test Tool.toToolParam encoding")
    func testToToolParamSerialization() {
        let tool = ComplexMockTool()

        // This should not crash or fallback to an empty dictionary
        let param = tool.toToolParam()

        #expect(param.function.name == "complex_tool")
        #expect(param.function.description == "A tool with nested parameters")

        // Verify the properties encoded correctly. 
        // We know parametersSchema was processed cleanly if JSONSchema isn't empty.

        guard case .object(let properties) = param.function.parameters else {
            Issue.record("Parameters should be of type .object")
            return
        }

        #expect(properties != [:], "Schema encoding failed, resulted in empty properties")

        let schemaString = String(data: try! JSONEncoder().encode(properties), encoding: .utf8)!

        // Ensure complex types carried over
        #expect(schemaString.contains("\"query\""))
        #expect(schemaString.contains("\"count\""))
        #expect(schemaString.contains("\"recursive\""))
    }
}
