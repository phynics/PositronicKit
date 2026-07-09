import Foundation
import struct JSONSchema.Schema
import PKShared

public extension PKShared.Tool {
    func toLLMToolDefinition() -> LLMToolDefinition {
        // parametersSchema is now the typed `Schema` (matching LLMToolDefinition.parameters),
        // so it flows through directly with no encode/decode round-trip.
        LLMToolDefinition(
            name: id,
            description: description,
            parameters: parametersSchema
        )
    }
}
