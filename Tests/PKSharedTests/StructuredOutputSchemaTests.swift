import Foundation
import Testing
import struct JSONSchema.Schema
@testable import PKShared

@Suite("Structured Output Schema Tests")
struct StructuredOutputSchemaTests {
    @Test("Stores JSONSchema primitives directly")
    func storesJSONSchemaPrimitivesDirectly() throws {
        let schema = try Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)

        let structuredSchema = StructuredOutputSchema(
            name: "tag_payload",
            schema: schema
        )

        let encoded = try JSONEncoder().encode(structuredSchema.schema)
        let encodedString = String(decoding: encoded, as: UTF8.self)

        #expect(encodedString.contains("\"type\":\"object\""))
        #expect(encodedString.contains("\"tags\""))
    }
}
