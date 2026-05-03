import Foundation
import struct JSONSchema.Schema
import Logging
import PKShared

public extension PKShared.Tool {
    func toLLMToolDefinition() -> LLMToolDefinition {
        // parametersSchema is [String: AnyCodable] — use JSONEncoder (Codable-aware) not
        // JSONSerialization, which cannot handle the AnyCodable wrapper (__SwiftValue crash).
        let schema: Schema
        if let data = try? JSONEncoder().encode(parametersSchema),
           let decoded = try? JSONDecoder().decode(Schema.self, from: data) {
            schema = decoded
        } else {
            Logger(label: "com.positronickit.tools").warning(
                "Failed to decode parametersSchema for tool '\(id)' — using empty schema. Raw: \(parametersSchema)"
            )
            schema = makeEmptyObjectSchema()
        }

        return LLMToolDefinition(
            name: id,
            description: description,
            parameters: schema
        )
    }
}
