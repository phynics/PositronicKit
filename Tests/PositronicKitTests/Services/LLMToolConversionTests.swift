import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKContracts
import PKUtilities
import Testing
@testable import PositronicKit

@Suite("LLM tool conversion")
struct LLMToolConversionTests {
    struct ComplexMockTool: PKContracts.Tool {
        let callName = "complex_tool"
        let name = "Complex Tool"
        let description = "A tool with nested parameters"
        let requiresPermission = false

        var parametersSchema: Schema {
            ToolParameterSchema.object {
                JSONProperty(key: "query") {
                    JSONString().description("Search query")
                }
                JSONProperty(key: "count") {
                    JSONInteger().description("number of items")
                }
                JSONProperty(key: "recursive") {
                    JSONBoolean().description("Whether to search recursively")
                }
            }.schemaDefinition
        }

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("Executed")
        }
    }

    @Test("converts PKContracts tool definitions into neutral LLM tool definitions")
    func convertsToolToLLMToolDefinition() {
        let tool = ComplexMockTool()
        let param = tool.toLLMToolDefinition()

        #expect(param.name == "complex_tool")
        #expect(param.description == "A tool with nested parameters")

        guard let schema = param.parameters,
              let data = try? JSONEncoder().encode(schema),
              let schemaString = String(data: data, encoding: .utf8)
        else {
            Issue.record("Parameters should be of type .object")
            return
        }

        #expect(schemaString.contains("\"query\""))
        #expect(schemaString.contains("\"count\""))
        #expect(schemaString.contains("\"recursive\""))
    }
}
