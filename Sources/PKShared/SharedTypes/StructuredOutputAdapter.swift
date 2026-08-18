import Foundation
import struct JSONSchema.Schema

/// The result of preparing a structured-output request for a specific provider.
///
/// Provider-specific adapters transform the neutral request (messages, tools, schema)
/// into the shape their wire protocol expects. The core runtime consumes this value
/// and applies the transformed fields to the streaming request.
public struct PreparedStructuredOutputRequest: Sendable {
    /// Messages to send, possibly with `promptAugmentation` appended to the trailing user message.
    public let messages: [LLMMessage]
    /// Tools to send, including any synthetic tool injected to carry the structured schema.
    public let tools: [LLMToolDefinition]?
    /// Tool-choice constraint; set to force the synthetic structured-output tool where used.
    public let toolChoice: LLMToolChoice?
    /// Native response-format constraint, when the provider supports one directly (`nil` when
    /// structured output is instead carried via a synthetic tool call).
    public let responseFormat: LLMResponseFormat?
    /// Name of the synthetic tool injected to carry the schema, if one was used; the runtime
    /// uses this to recognize and unwrap the tool call as the structured response.
    public let syntheticToolName: String?
    /// Extra prompt text appended to steer providers with no native structured-output support.
    public let promptAugmentation: String?

    public init(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        syntheticToolName: String? = nil,
        promptAugmentation: String? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
        self.syntheticToolName = syntheticToolName
        self.promptAugmentation = promptAugmentation
    }
}

/// Provider-specific preparation of structured-output requests.
///
/// Concrete implementations live in dedicated provider targets (`PKOpenAIProvider`,
/// `PKOllamaProvider`, etc.) and are supplied by the client that uses them. This keeps
/// provider knowledge out of the core runtime without global mutable registration.
public protocol StructuredOutputAdapter: Sendable {
    /// Transforms a neutral structured-output request into the provider-specific shape.
    func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest
}

public extension StructuredOutputAdapter {
    /// Handles the `.jsonObject` case uniformly. Providers should call this from their
    /// `prepareRequest` for the `.jsonObject` case.
    func jsonObjectRequest(messages: [LLMMessage], tools: [LLMToolDefinition]?) -> PreparedStructuredOutputRequest {
        PreparedStructuredOutputRequest(
            messages: messages,
            tools: tools,
            toolChoice: nil,
            responseFormat: .jsonObject
        )
    }
}

/// Structured-output preparation shared by providers whose wire protocol natively
/// supports both `json_object` and `json_schema` response formats (e.g. OpenAI,
/// OpenRouter), forwarding the schema without synthetic tools or prompt augmentation.
public struct NativeJSONSchemaStructuredOutputAdapter: StructuredOutputAdapter {
    public init() {}

    public func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
        switch output {
        case .jsonObject:
            return jsonObjectRequest(messages: messages, tools: tools)
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

/// Conservative fallback for clients with no specialized adapter.
///
/// - `.jsonObject` is forwarded with a native JSON-object response format.
/// - `.jsonSchema` is converted to a forced synthetic tool call, which is the most
///   widely supported mechanism for providers that do not expose a native schema
///   response format.
public struct DefaultStructuredOutputAdapter: StructuredOutputAdapter {
    private let syntheticToolName = "emit_structured_response"

    public init() {}

    public func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
        switch output {
        case .jsonObject:
            return jsonObjectRequest(messages: messages, tools: tools)
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

/// Structured-output adapter that augments the prompt with the schema text and emits
/// a `json_schema` response format. Used by OpenAI-compatible and Ollama providers.
public struct PromptAugmentedJSONSchemaAdapter: StructuredOutputAdapter {
    public init() {}

    public func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
        switch output {
        case .jsonObject:
            return jsonObjectRequest(messages: messages, tools: tools)
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

// MARK: - Shared helpers

package func makeSyntheticStructuredOutputTool(
    for schema: StructuredOutputSchema,
    name: String
) -> LLMToolDefinition {
    LLMToolDefinition(
        name: name,
        description: schema.description ?? "Emit the final structured response payload for \(schema.name).",
        parameters: schema.schema,
        strict: schema.strict
    )
}

package func fallbackStructuredOutputPromptSuffix(for schema: StructuredOutputSchema) -> String {
    let schemaString: String
    if let data = try? JSONEncoder().encode(schema.schema) {
        schemaString = String(decoding: data, as: UTF8.self)
    } else {
        schemaString = "{}"
    }
    return """

    Return ONLY valid JSON that matches this JSON Schema exactly.
    Schema name: \(schema.name)
    JSON Schema:
    \(schemaString)
    """
}

package func applyStructuredOutputPromptAugmentation(
    _ augmentation: String,
    to messages: [LLMMessage]
) -> [LLMMessage] {
    var updatedMessages = messages

    for index in updatedMessages.indices.reversed() {
        guard updatedMessages[index].role == .user else { continue }
        updatedMessages[index] = LLMMessage(
            role: .user,
            content: updatedMessages[index].content + augmentation,
            name: updatedMessages[index].name,
            toolCallID: updatedMessages[index].toolCallID,
            toolCalls: updatedMessages[index].toolCalls
        )
        return updatedMessages
    }

    updatedMessages.append(LLMMessage(
        role: .user,
        content: augmentation.trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    return updatedMessages
}
