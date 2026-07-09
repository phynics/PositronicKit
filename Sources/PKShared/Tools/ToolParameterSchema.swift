import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Type-safe JSON Schema builder for tool parameters.
///
/// A thin builder helper around `JSONSchemaBuilder`'s `JSONObject`/`JSONPropertySchemaBuilder` DSL:
/// `ToolParameterSchema.object { ... }.schemaDefinition` yields the typed `Schema` that
/// ``Tool/parametersSchema`` returns. Kept as a convenience so tool conformers don't have to spell
/// out `JSONObject(with:).definition()` directly.
public struct ToolParameterSchema: Sendable {
    public let schemaDefinition: Schema

    public init(schemaDefinition: Schema) {
        self.schemaDefinition = schemaDefinition
    }

    public static func object<Props: PropertyCollection>(
        @JSONPropertySchemaBuilder _ build: () -> Props
    ) -> ToolParameterSchema {
        ToolParameterSchema(schemaDefinition: JSONObject(with: build).definition())
    }
}

extension Schema {
    /// Encodes this JSON Schema to the `[String: AnyCodable]` wire/transfer form used by
    /// `WorkspaceToolDefinition` and by dynamic schema introspection (e.g. the FoundationModels
    /// bridge). Round-trips through `JSONEncoder`/`JSONDecoder` since `Schema` is `Codable`.
    /// Returns an empty object schema dictionary on encode/decode failure.
    public var asDictionary: [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(self),
              let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else {
            return ["type": .string("object"), "properties": .dictionary([:])]
        }
        return decoded
    }

    /// Builds a `Schema` from a `[String: AnyCodable]` JSON-Schema-shaped dictionary (the
    /// `WorkspaceToolDefinition` transfer form). Falls back to an empty object schema on failure.
    public init(_ dictionary: [String: AnyCodable]) {
        if let data = try? JSONEncoder().encode(dictionary),
           let decoded = try? JSONDecoder().decode(Schema.self, from: data)
        {
            self = decoded
        } else {
            self = ToolParameterSchema.object {}.schemaDefinition
        }
    }
}
