import Foundation
import PKShared
import PKUtilities

/// Structured-output preparation for the Anthropic Messages API.
///
/// Anthropic's Messages API has no native JSON Schema response format, so this
/// adapter expresses the schema as a forced synthetic tool call whose arguments
/// carry the structured payload.
public struct AnthropicStructuredOutputAdapter: StructuredOutputAdapter {
    private let syntheticToolName = "emit_structured_response"

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
            let syntheticTool = makeSyntheticStructuredOutputTool(
                for: schema,
                name: syntheticToolName
            )
            return PreparedStructuredOutputRequest(
                messages: messages,
                tools: (tools ?? []) + [syntheticTool],
                toolChoice: .function(syntheticToolName),
                responseFormat: nil,
                syntheticToolName: syntheticToolName
            )
        }
    }
}
