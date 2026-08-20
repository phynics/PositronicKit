import Testing
import Foundation
import JSONSchemaBuilder
@testable import PKContracts

@Suite("Tool Parameter Schema Tests")
struct ToolParameterSchemaTests {

    @Test("Basic Object Building")
    func testBasicObject() {
        let schema = ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("File path")
            }
            .required()
            JSONProperty(key: "limit") {
                JSONInteger().description("Max lines")
            }
            JSONProperty(key: "recursive") {
                JSONBoolean().description("Search recursively")
            }
        }

        let dict = schema.schemaDefinition.asDictionary
        #expect(dict["type"]?.asString == "object")

        guard let properties = dict["properties"]?.asDictionary else {
            Issue.record("Missing properties")
            return
        }

        #expect(properties["path"]?.asDictionary?["type"]?.asString == "string")
        #expect(properties["path"]?.asDictionary?["description"]?.asString == "File path")

        #expect(properties["limit"]?.asDictionary?["type"]?.asString == "integer")

        #expect(properties["recursive"]?.asDictionary?["type"]?.asString == "boolean")

        guard let required = dict["required"]?.asArray else {
            Issue.record("Missing required array")
            return
        }

        #expect(required.contains(.string("path")))
        #expect(!required.contains(.string("limit")))
    }

    @Test("String Enum Building")
    func testStringEnum() {
        let schema = ToolParameterSchema.object {
            JSONProperty(key: "mode") {
                JSONString()
                    .description("Execution mode")
                    .enumValues {
                        "fast"
                        "safe"
                    }
            }
            .required()
        }

        let dict = schema.schemaDefinition.asDictionary
        guard let properties = dict["properties"]?.asDictionary else {
            Issue.record("Missing properties")
            return
        }

        let modeProps = properties["mode"]?.asDictionary
        #expect(modeProps?["type"]?.asString == "string")
        #expect(modeProps?["enum"]?.asArray == [.string("fast"), .string("safe")])
    }
}
