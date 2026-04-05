import Testing
import Foundation
@testable import MonadShared

@Suite("Tool Parameter Schema Tests")
struct ToolParameterSchemaTests {

    @Test("Basic Object Building")
    func testBasicObject() {
        let schema = ToolParameterSchema.object { b in
            b.string("path", description: "File path", required: true)
            b.integer("limit", description: "Max lines", required: false)
            b.boolean("recursive", description: "Search recursively")
        }

        let dict = schema.schema
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
        let schema = ToolParameterSchema.object { b in
            b.stringEnum("mode", description: "Execution mode", values: ["fast", "safe"], required: true)
        }

        let dict = schema.schema
        guard let properties = dict["properties"]?.asDictionary else {
            Issue.record("Missing properties")
            return
        }

        let modeProps = properties["mode"]?.asDictionary
        #expect(modeProps?["type"]?.asString == "string")
        #expect(modeProps?["enum"]?.asArray == [.string("fast"), .string("safe")])
    }
}
