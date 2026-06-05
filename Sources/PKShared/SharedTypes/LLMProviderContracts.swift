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

    public init(
        role: Role,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

public struct LLMTokenUsagePromptDetails: Sendable, Codable, Equatable {
    public let cachedTokens: Int?

    public init(cachedTokens: Int? = nil) {
        self.cachedTokens = cachedTokens
    }
}

public struct LLMTokenUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let promptTokensDetails: LLMTokenUsagePromptDetails?

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
    public let toolCalls: [LLMToolCallDelta]?

    public init(role: LLMMessage.Role? = nil, content: String? = nil, toolCalls: [LLMToolCallDelta]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}

public struct LLMStreamChoice: Sendable, Codable, Equatable {
    public let index: Int
    public let delta: LLMStreamDelta
    public let finishReason: String?

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

public enum ExternalLLMProviderRegistry {
    public typealias Factory = @Sendable (
        LLMConfiguration,
        EndpointComponents,
        TimeInterval,
        Int,
        String?
    ) -> (any LLMClientProtocol)?

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
    if let data = "{\"type\":\"object\",\"properties\":{}}".data(using: .utf8),
       let schema = try? JSONDecoder().decode(Schema.self, from: data) {
        return schema
    }
    fatalError("Failed to construct empty object schema")
}

private func encodeSchema(_ schema: Schema?) -> String? {
    guard let schema, let data = try? JSONEncoder().encode(schema) else { return nil }
    return String(decoding: data, as: UTF8.self)
}
