import Foundation
import PKShared
import PKUtilities

/// Structured-output preparation for generic OpenAI-compatible endpoints.
///
/// Most modern OpenAI-compatible servers (LM Studio, vLLM, llama.cpp, etc.) support
/// the native `json_schema` response format. This adapter sends the schema as a
/// `response_format` constraint and also augments the prompt with the schema text,
/// mirroring the Ollama adapter's belt-and-suspenders approach. This avoids relying
/// on synthetic tool calls, which many local models and servers handle poorly or not
/// at all (no `tool_choice: "function"` support, no tool-call fine-tuning, etc.).
public struct OpenAICompatibleStructuredOutputAdapter: StructuredOutputAdapter {
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
