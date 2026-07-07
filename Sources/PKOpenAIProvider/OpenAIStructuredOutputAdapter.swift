import Foundation
import PKShared

/// Structured-output preparation for the native OpenAI Chat Completions API.
///
/// OpenAI supports both `json_object` and `json_schema` response formats natively,
/// so this adapter forwards the schema without synthetic tools or prompt augmentation.
public struct OpenAIStructuredOutputAdapter: StructuredOutputAdapter {
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
