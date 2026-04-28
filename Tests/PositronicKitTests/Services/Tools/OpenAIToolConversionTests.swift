import Foundation
import JSONSchemaBuilder
import OpenAI
import PKShared
import Testing
@testable import PositronicKit

@Suite("OpenAI tool conversion")
struct OpenAIToolConversionTests {
    struct ComplexMockTool: PKShared.Tool {
        let id = "complex_tool"
        let name = "Complex Tool"
        let description = "A tool with nested parameters"
        let requiresPermission = false

        var parametersSchema: [String: AnyCodable] {
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
            }.schema
        }

        func canExecute() async -> Bool { true }

        func execute(parameters: [String: Any]) async throws -> ToolResult {
            .success("Executed")
        }
    }

    @Test("converts PKShared tool definitions into OpenAI tool params in PositronicKit")
    func convertsToolToOpenAIParam() {
        let tool = ComplexMockTool()
        let param = tool.toOpenAIToolParam()

        #expect(param.function.name == "complex_tool")
        #expect(param.function.description == "A tool with nested parameters")

        guard case .object(let properties) = param.function.parameters else {
            Issue.record("Parameters should be of type .object")
            return
        }

        #expect(properties != [:], "Schema encoding failed, resulted in empty properties")

        let schemaString = String(data: try! JSONEncoder().encode(properties), encoding: .utf8)!
        #expect(schemaString.contains("\"query\""))
        #expect(schemaString.contains("\"count\""))
        #expect(schemaString.contains("\"recursive\""))
    }
}
