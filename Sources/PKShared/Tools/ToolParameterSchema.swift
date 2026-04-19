import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Type-safe JSON Schema builder for tool parameters
public struct ToolParameterSchema: Sendable {
    public let schemaDefinition: Schema

    public var schema: [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(schemaDefinition),
              let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    public init(schemaDefinition: Schema) {
        self.schemaDefinition = schemaDefinition
    }

    public static func object<Props: PropertyCollection>(
        @JSONPropertySchemaBuilder _ build: () -> Props
    ) -> ToolParameterSchema {
        ToolParameterSchema(schemaDefinition: JSONObject(with: build).definition())
    }
}
