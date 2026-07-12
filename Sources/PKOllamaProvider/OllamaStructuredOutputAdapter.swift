import Foundation
import PKShared
import PKUtilities

/// Structured-output preparation for the Ollama API.
///
/// Ollama does not reliably honor a JSON Schema response format on all models, so
/// this adapter augments the final user message with the schema and still emits a
/// compatible response format when the model supports it.
public struct OllamaStructuredOutputAdapter: StructuredOutputAdapter {
    public init() {}

    public func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
        switch output {
        case .jsonObject:
            return PreparedStructuredOutputRequest(
                messages: messages,
                tools: tools,
                toolChoice: nil,
                responseFormat: .jsonObject
            )
        case let .jsonSchema(schema):
            let augmentation = fallbackStructuredOutputPromptSuffix(for: schema)
            return PreparedStructuredOutputRequest(
                messages: applyStructuredOutputPromptAugmentation(augmentation, to: messages),
                tools: tools,
                toolChoice: nil,
                responseFormat: .jsonSchema(.init(
                    name: schema.name,
                    description: schema.description,
                    schema: schema.schema,
                    strict: schema.strict
                )),
                promptAugmentation: augmentation
            )
        }
    }
}
