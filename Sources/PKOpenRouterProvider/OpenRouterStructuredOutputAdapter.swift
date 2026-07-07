import Foundation
import PKShared

/// Structured-output preparation for the OpenRouter API.
///
/// OpenRouter mirrors OpenAI's response-format support, so this adapter uses the
/// same native JSON-schema path while keeping provider ownership in the dedicated
/// OpenRouter target.
public struct OpenRouterStructuredOutputAdapter: StructuredOutputAdapter {
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
            return PreparedStructuredOutputRequest(
                messages: messages,
                tools: tools,
                toolChoice: nil,
                responseFormat: .jsonSchema(.init(
                    name: schema.name,
                    description: schema.description,
                    schema: schema.schema,
                    strict: schema.strict
                ))
            )
        }
    }
}
