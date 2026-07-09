import Foundation
import struct JSONSchema.Schema
import PKShared

/// Reusable JSON Schema fixtures for tests exercising structured-output request/response handling.
public enum StructuredOutputFixtures {
    /// Schema for a single required `tags: [String]` field, e.g. for tagging-tool tests.
    public static let tagSchema = try! Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)

    /// Wraps ``tagSchema`` in a named `StructuredOutputSchema` request payload.
    public static func tagSchemaDefinition(name: String = "tag_payload") -> StructuredOutputSchema {
        StructuredOutputSchema(name: name, schema: tagSchema)
    }
}
