import Foundation
import Synchronization
import struct JSONSchema.Schema

/// The result of preparing a structured-output request for a specific provider.
///
/// Provider-specific adapters transform the neutral request (messages, tools, schema)
/// into the shape their wire protocol expects. The core runtime consumes this value
/// and applies the transformed fields to the streaming request.
public struct PreparedStructuredOutputRequest: Sendable {
    public let messages: [LLMMessage]
    public let tools: [LLMToolDefinition]?
    public let toolChoice: LLMToolChoice?
    public let responseFormat: LLMResponseFormat?
    public let syntheticToolName: String?
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
/// `PKOllamaProvider`, etc.) and are registered via `StructuredOutputAdapterRegistry`.
/// This keeps provider knowledge out of the core runtime while still allowing hosts to
/// plug in custom behavior for arbitrary providers.
public protocol StructuredOutputAdapter: Sendable {
    func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest
}

/// Registry mapping `LLMProvider` values to their structured-output adapters.
///
/// Provider modules register their adapter in their public `register()` entry point.
/// The core runtime looks up the adapter for the configured provider and falls back
/// to `DefaultStructuredOutputAdapter` when none is registered.
public enum StructuredOutputAdapterRegistry {
    private static let adapters = Mutex<[LLMProvider: any StructuredOutputAdapter]>([:])

    public static func register(_ adapter: any StructuredOutputAdapter, for provider: LLMProvider) {
        adapters.withLock { $0[provider] = adapter }
    }

    public static func adapter(for provider: LLMProvider) -> (any StructuredOutputAdapter)? {
        adapters.withLock { $0[provider] }
    }
}

/// Conservative fallback for providers with no registered adapter.
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
