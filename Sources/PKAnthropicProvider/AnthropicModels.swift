import Foundation
import struct JSONSchema.Schema
import Logging
import PKShared
import PKUtilities

// MARK: - JSON value bridging

/// Minimal JSON value model used to carry a tool call's already-serialized `arguments` JSON
/// string into Anthropic's structured `tool_use.input` field, which is a JSON object on the
/// wire (not a string like the OpenAI-family `function.arguments`).
enum AnthropicJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnthropicJSONValue])
    case object([String: AnthropicJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnthropicJSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: AnthropicJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Parses a JSON object string (e.g. `LLMToolCall.arguments`) into a JSON value.
    /// Returns `nil` when the string is not valid JSON.
    static func fromJSONString(_ string: String) -> AnthropicJSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnthropicJSONValue.self, from: data)
    }
}

// MARK: - Request payload

struct AnthropicChatRequest: Encodable {
    let model: String
    /// Required by the Messages API (unlike the OpenAI family, where it is optional).
    /// Defaulted by the client when `GenerationParameters.maxTokens` is absent.
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?
    let temperature: Double?
    let topP: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, temperature, stream
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case topP = "top_p"
    }
}

struct AnthropicMessage: Encodable, Equatable {
    let role: String
    var content: [AnthropicContentBlock]
}

enum AnthropicContentBlock: Encodable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: AnthropicJSONValue)
    case toolResult(toolUseID: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseID = "tool_use_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .toolUse(id, name, input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
        }
    }
}

struct AnthropicTool: Encodable {
    let name: String
    let description: String?
    let inputSchema: Schema

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }

    init(_ tool: LLMToolDefinition) {
        name = tool.name
        description = tool.description
        inputSchema = tool.parameters ?? makeEmptyObjectSchema()
    }
}

enum AnthropicToolChoice: Encodable {
    case auto
    case tool(String)

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case let .tool(name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Message conversion

enum AnthropicMessageConversion {
    /// Converts transport-neutral messages into the Messages API shape.
    ///
    /// - `system`/`developer` roles are hoisted into the top-level `system` parameter (the
    ///   Messages API rejects system-role entries inside `messages`).
    /// - Assistant tool calls become `tool_use` content blocks; tool-role results become
    ///   user-role `tool_result` blocks, preserving id pairing (PKINT-002).
    /// - Consecutive same-role messages are merged into one message with multiple content
    ///   blocks, since the Messages API requires alternating user/assistant turns.
    /// - `LLMMessage.reasoning` is intentionally NOT echoed: Anthropic thinking blocks carry a
    ///   provider-issued cryptographic signature that PositronicKit does not persist, and
    ///   unsigned thinking blocks are rejected by the API.
    static func convert(
        messages: [LLMMessage],
        logger: Logger
    ) throws -> (system: String?, messages: [AnthropicMessage]) {
        try validateLLMMessageHistory(messages)
        var systemParts: [String] = []
        var converted: [AnthropicMessage] = []

        func append(role: String, blocks: [AnthropicContentBlock]) {
            guard !blocks.isEmpty else { return }
            if var last = converted.last, last.role == role {
                last.content.append(contentsOf: blocks)
                converted[converted.count - 1] = last
            } else {
                converted.append(AnthropicMessage(role: role, content: blocks))
            }
        }

        for message in messages {
            switch message.role {
            case .system, .developer:
                if !message.content.isEmpty {
                    systemParts.append(message.content)
                }
            case .user:
                append(role: "user", blocks: [.text(message.content)])
            case .assistant:
                var blocks: [AnthropicContentBlock] = []
                if !message.content.isEmpty {
                    blocks.append(.text(message.content))
                }
                for call in message.toolCalls ?? [] {
                    let input: AnthropicJSONValue
                    if let parsed = AnthropicJSONValue.fromJSONString(call.arguments) {
                        input = parsed
                    } else {
                        logger.warning(
                            "Anthropic tool_use input for call \(call.id) (\(call.name)) is not valid JSON; sending an empty object instead."
                        )
                        input = .object([:])
                    }
                    blocks.append(.toolUse(id: call.id, name: call.name, input: input))
                }
                append(role: "assistant", blocks: blocks)
            case .tool:
                guard let toolCallID = message.toolCallID, !toolCallID.isEmpty else {
                    throw LLMMessageValidationError.missingToolCallID
                }
                append(
                    role: "user",
                    blocks: [.toolResult(toolUseID: toolCallID, content: message.content)]
                )
            }
        }

        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return (system, converted)
    }
}

// MARK: - Streaming events

/// One decoded Messages API SSE event. The Anthropic stream is event-based
/// (`message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` /
/// `message_delta` / `message_stop`), a materially different shape from the OpenAI-family
/// per-chunk deltas, so it gets its own decoding path before mapping to `LLMStreamChunk`.
struct AnthropicStreamEvent: Decodable {
    struct MessageStart: Decodable {
        let id: String
        let model: String
        let usage: Usage?
    }

    struct ContentBlockStart: Decodable {
        let type: String
        let id: String?
        let name: String?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let partialJson: String?
        let thinking: String?
        let stopReason: String?
        let stopSequence: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
    }

    struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }

    let type: String
    let message: MessageStart?
    let index: Int?
    let contentBlock: ContentBlockStart?
    let delta: Delta?
    let usage: Usage?
    let error: ErrorBody?
}

/// Maps an Anthropic `stop_reason` onto the shared `FinishReason` vocabulary (PKR-13).
func mapAnthropicStopReason(_ stopReason: String) -> FinishReason {
    switch stopReason {
    case "end_turn", "stop_sequence":
        return .stop
    case "max_tokens":
        return .length
    case "tool_use":
        return .toolCalls
    case "refusal":
        return .contentFilter
    default:
        return .other(stopReason)
    }
}

// MARK: - Models listing

struct AnthropicModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
