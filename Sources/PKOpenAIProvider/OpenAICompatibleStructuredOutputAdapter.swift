import Foundation
import PKShared

/// Structured-output preparation for generic OpenAI-compatible endpoints that do not
/// expose a native JSON Schema response format.
///
/// This adapter uses the same forced synthetic-tool mechanism as Anthropic so that
/// structured output works consistently across providers that only support tool-based
/// schema enforcement.
public struct OpenAICompatibleStructuredOutputAdapter: StructuredOutputAdapter {
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
