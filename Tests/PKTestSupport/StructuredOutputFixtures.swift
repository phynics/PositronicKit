import Foundation
import struct JSONSchema.Schema
import PKShared

public enum StructuredOutputFixtures {
    public static let tagSchema = try! Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)

    public static func tagSchemaDefinition(name: String = "tag_payload") -> StructuredOutputSchema {
        StructuredOutputSchema(name: name, schema: tagSchema)
    }
}
