import Foundation
import struct JSONSchema.Schema
import Synchronization

public struct LLMToolDefinition: Sendable, Codable {
    public let name: String
    public let description: String?
    public let parameters: Schema?
    public let strict: Bool?

    public init(
        name: String,
        description: String? = nil,
        parameters: Schema? = nil,
        strict: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

public enum LLMToolChoice: Sendable, Codable, Equatable {
    case auto
    case function(String)
}

public enum LLMResponseFormat: Sendable, Codable, Equatable {
    case text
    case jsonObject
    case jsonSchema(LLMResponseSchema)

    public static func == (lhs: LLMResponseFormat, rhs: LLMResponseFormat) -> Bool {
        switch (lhs, rhs) {
        case (.text, .text), (.jsonObject, .jsonObject):
            return true
        case let (.jsonSchema(lhsSchema), .jsonSchema(rhsSchema)):
            return lhsSchema == rhsSchema
        default:
            return false
        }
    }
}

public struct LLMResponseSchema: Sendable, Codable, Equatable {
    public let name: String
    public let description: String?
    public let schema: Schema?
    public let strict: Bool?

    public init(
        name: String,
        description: String? = nil,
        schema: Schema? = nil,
        strict: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
    }

    public static func == (lhs: LLMResponseSchema, rhs: LLMResponseSchema) -> Bool {
        lhs.name == rhs.name &&
            lhs.description == rhs.description &&
            lhs.strict == rhs.strict &&
            encodeSchema(lhs.schema) == encodeSchema(rhs.schema)
    }
}

public struct LLMToolCall: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct LLMMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
        case developer
    }

    public let role: Role
    public let content: String
    public let name: String?
    public let toolCallID: String?
    public let toolCalls: [LLMToolCall]?

    /// Structured reasoning/thinking to echo back on follow-up turns for reasoning models that
    /// require it (STAB-8). Threaded from persisted `Message.reasoning` by the history-reconstruction
    /// path (`RenderedPrompt.buildMessages()` / `buildAssistantMessage`). The field name is
    /// provider-neutral; each provider adapter maps it onto its own wire field:
    /// Ollama → `thinking`, OpenRouter → `reasoning`. The OpenAI Chat Completions adapter
    /// intentionally omits it (the Chat Completions API has no reasoning-echo message field;
    /// reasoning continuation there uses the Responses API / `previous_response_id`, which is
    /// out of scope). `nil` for non-reasoning flows — existing messages are byte-identical.
    public let reasoning: String?

    public init(
        role: Role,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.reasoning = reasoning
    }
}

public struct LLMTokenUsagePromptDetails: Sendable, Codable, Equatable {
    public let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }

    public init(cachedTokens: Int? = nil) {
        self.cachedTokens = cachedTokens
    }
}

public struct LLMTokenUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let promptTokensDetails: LLMTokenUsagePromptDetails?

    /// Shared streaming usage metadata stays snake_case-safe here so providers can decode
    /// directly into the transport-neutral contract without relying on decoder-wide conversion.
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        promptTokensDetails: LLMTokenUsagePromptDetails? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptTokensDetails = promptTokensDetails
    }
}

public struct LLMToolCallDeltaFunction: Sendable, Codable, Equatable {
    public let name: String?
    public let arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct LLMToolCallDelta: Sendable, Codable, Equatable {
    public let index: Int?
    public let id: String?
    public let function: LLMToolCallDeltaFunction?

    public init(index: Int? = nil, id: String? = nil, function: LLMToolCallDeltaFunction? = nil) {
        self.index = index
        self.id = id
        self.function = function
    }
}

public struct LLMStreamDelta: Sendable, Codable, Equatable {
    public let role: LLMMessage.Role?
    public let content: String?
    /// Structured reasoning/thinking delta emitted as a distinct field by some providers
    /// (e.g. OpenRouter `delta.reasoning`, OpenAI reasoning models' `reasoning`/`reasoning_content`,
    /// Ollama thinking models' `thinking`). Routed directly into `TurnOutputs.appendThinking` by
    /// `LLMStreamingStage`. `nil` for non-reasoning models — existing flows are byte-identical.
    /// The `<think>...</think>` tag-scraping path in `StreamingParser` remains the fallback for
    /// models that emit inline reasoning text inside `content`.
    public let reasoning: String?

    public let toolCalls: [LLMToolCallDelta]?

    /// `tool_calls` is part of the shared streaming contract, so it is spelled out explicitly
    /// instead of depending on a decoder-wide snake_case conversion.
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoning
        case toolCalls = "tool_calls"
    }

    public init(
        role: LLMMessage.Role? = nil,
        content: String? = nil,
        reasoning: String? = nil,
        toolCalls: [LLMToolCallDelta]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
    }
}

public struct LLMStreamChoice: Sendable, Codable, Equatable {
    public let index: Int
    public let delta: LLMStreamDelta
    public let finishReason: String?

    /// `finish_reason` is part of the streaming wire contract and must survive decode intact.
    enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
    }

    public init(index: Int, delta: LLMStreamDelta, finishReason: String? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }
}

public struct LLMStreamChunk: Sendable, Codable, Equatable {
    public let id: String
    public let model: String
    public let choices: [LLMStreamChoice]
    public let usage: LLMTokenUsage?

    public init(id: String, model: String, choices: [LLMStreamChoice], usage: LLMTokenUsage? = nil) {
        self.id = id
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

public struct EndpointComponents: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let scheme: String

    public init(host: String, port: Int, scheme: String) {
        self.host = host
        self.port = port
        self.scheme = scheme
    }
}

public protocol LLMClientProtocol: Sendable {
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error>

    func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async throws -> String

    func fetchAvailableModels() async throws -> [String]?
}

public extension LLMClientProtocol {
    func fetchAvailableModels() async throws -> [String]? {
        nil
    }
}

/// Labeled request payload for constructing a provider client via
/// ``ExternalLLMProviderRegistry/Factory``.
///
/// Replaces the former unlabeled 5-tuple
/// `(LLMConfiguration, EndpointComponents, TimeInterval, Int, String?)` — Swift closure type
/// aliases can't carry argument labels, so `TimeInterval`, `Int`, and `String?` were
/// unidentifiable at any call site. The struct makes every field self-documenting.
public struct ProviderFactoryRequest: Sendable {
    /// The resolved LLM configuration (active provider's settings live at
    /// `config.providers[config.activeProvider]`).
    public let config: LLMConfiguration
    /// Parsed host/port/scheme of `config.endpoint`.
    public let components: EndpointComponents
    /// Per-request HTTP timeout interval.
    public let timeout: TimeInterval
    /// Per-request retry count.
    public let retries: Int
    /// Optional model-name override; `nil` means use `config.modelName` (or the tier-specific
    /// model for utility/fast client construction).
    public let model: String?

    public init(
        config: LLMConfiguration,
        components: EndpointComponents,
        timeout: TimeInterval,
        retries: Int,
        model: String? = nil
    ) {
        self.config = config
        self.components = components
        self.timeout = timeout
        self.retries = retries
        self.model = model
    }
}

public enum ExternalLLMProviderRegistry {
    /// Constructs a provider client from a labeled ``ProviderFactoryRequest``.
    public typealias Factory = @Sendable (ProviderFactoryRequest) -> (any LLMClientProtocol)?

    private static let factories = Mutex<[LLMProvider: Factory]>([:])

    /// Registers or replaces the factory for a provider.
    ///
    /// Re-registration is allowed and simply overwrites the existing factory for that provider.
    /// Provider modules rely on this behavior so hosts can call `register()` defensively at startup.
    public static func register(factory: @escaping Factory, for provider: LLMProvider) {
        factories.withLock {
            $0[provider] = factory
        }
    }

    public static func factory(for provider: LLMProvider) -> Factory? {
        factories.withLock {
            $0[provider]
        }
    }
}

public func makeEmptyObjectSchema() -> Schema {
    if let schema = try? Schema(instance: #"{"type":"object","properties":{}}"#) {
        return schema
    }
    return ToolParameterSchema.object {}.schemaDefinition
}

private func encodeSchema(_ schema: Schema?) -> String? {
    guard let schema, let data = try? JSONEncoder().encode(schema) else { return nil }
    return String(decoding: data, as: UTF8.self)
}
