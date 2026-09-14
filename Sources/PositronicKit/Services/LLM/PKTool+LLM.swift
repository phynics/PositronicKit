import Foundation
import struct JSONSchema.Schema
import PKContracts
import PKUtilities

public extension PKContracts.PKTool {
    func toLLMToolDefinition() -> LLMToolDefinition {
        // parametersSchema is now the typed `Schema` (matching LLMToolDefinition.parameters),
        // so it flows through directly with no encode/decode round-trip.
        LLMToolDefinition(
            name: callName,
            description: toolDescription,
            parameters: parametersSchema
        )
    }
}
