import Foundation
import struct JSONSchema.Schema
import Logging
import PKContracts
import PKUtilities

struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let format: OllamaResponseFormat?
    let tools: [OllamaTool]?
    let options: OllamaOptions?
}

enum OllamaResponseFormat: Codable {
    case jsonObject
    case jsonSchema(Schema)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .jsonObject:
            try container.encode("json")
        case let .jsonSchema(schema):
            try container.encode(schema)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "json" {
            self = .jsonObject
            return
        }
        self = try .jsonSchema(container.decode(Schema.self))
    }
}

struct OllamaOptions: Codable {
    let temperature: Double?
    let numPredict: Int?
    let topP: Double?
    let repeatPenalty: Double?
    let presencePenalty: Double?
    let seed: Int?

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
        case topP = "top_p"
        case repeatPenalty = "repeat_penalty"
        case presencePenalty = "presence_penalty"
        case seed
    }

    init(from params: GenerationParameters?) {
        temperature = params?.temperature
        numPredict = params?.maxTokens
        topP = params?.topP
        repeatPenalty = params?.frequencyPenalty
        presencePenalty = params?.presencePenalty
        seed = params?.seed
    }
}

struct OllamaTool: Codable {
    let type: String
    let function: OllamaToolFunction
}

struct OllamaToolFunction: Codable {
    let name: String
    let description: String
    let parameters: Schema
}

struct OllamaMessage: Codable {
    let role: String
    let content: String
    let images: [String]?
    /// Reasoning emitted by Ollama thinking models (e.g. qwen3-thinking) via the message's
    /// `thinking` field. Tolerates a legacy `think` key as a fallback when decoding responses.
    /// Included in `CodingKeys` so it IS encoded into outgoing request messages when present
    /// (echoing `thinking` back in history is required by Ollama thinking models to maintain
    /// reasoning context across turns — STAB-8). When `nil`, synthesis uses `encodeIfPresent`,
    /// so the key is omitted and non-reasoning request payloads stay byte-identical (STAB-7).
    let thinking: String?
    let toolCalls: [OllamaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case images
        case thinking
        case toolCalls = "tool_calls"
    }

    init(
        role: String,
        content: String,
        images: [String]? = nil,
        thinking: String? = nil,
        toolCalls: [OllamaToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.thinking = thinking
        self.toolCalls = toolCalls
    }

    /// Logger used when `LLMToolCall.arguments` fails to decode as the `[String: AnyCodable]`
    /// object shape Ollama's `/api/chat` endpoint requires for `tool_calls[].function.arguments`
    /// (PKR-12). Some models emit a JSON array or scalar instead of an object; silently
    /// substituting `{}` would send a wrong tool invocation with no diagnostic.
    private static let logger = Logger.module(named: "ollama-message-conversion")

    init(from param: LLMMessage, logger: Logger = OllamaMessage.logger) {
        if let converted = try? OllamaMessage(validating: param, logger: logger) {
            self = converted
        } else {
            self.init(
                role: param.role == .developer ? "system" : param.role.rawValue,
                content: param.content,
                thinking: param.reasoning,
                toolCalls: param.toolCalls?.compactMap { toolCall in
                    Self.makeOllamaToolCall(from: toolCall, logger: logger)
                }
            )
        }
    }

    init(validating param: LLMMessage, logger: Logger = OllamaMessage.logger) throws {
        let role = param.role == .developer ? "system" : param.role.rawValue
        let imageParts = param.messageContent.parts.compactMap { part -> ImageContent? in
            guard case let .image(image) = part else { return nil }
            return image
        }
        if param.messageContent.parts.contains(where: {
            if case .audio = $0 { return true }
            return false
        }) {
            throw MultimodalContentError.missingCapability(.audioInput)
        }
        if !imageParts.isEmpty, param.messageContent.parts.contains(where: {
            if case .text = $0 { return true }
            return false
        }) {
            throw MultimodalContentError.unsupportedContentLayout(provider: .ollama)
        }
        self.init(
            role: role,
            content: param.content,
            images: imageParts.isEmpty ? nil : imageParts.map { $0.data.base64EncodedString() },
            thinking: param.reasoning,
            toolCalls: param.toolCalls?.compactMap { toolCall in
                Self.makeOllamaToolCall(from: toolCall, logger: logger)
            }
        )
    }

    /// Converts a neutral `LLMToolCall` into the Ollama wire shape, decoding `arguments` (a raw
    /// JSON string) into the `[String: AnyCodable]` object Ollama expects. If the payload isn't a
    /// JSON object (e.g. some models emit a JSON array or scalar for `arguments`), the original
    /// value is preserved under a recoverable sentinel key instead of being silently dropped to
    /// `{}`, and a warning is logged so the substitution is diagnosable.
    private static func makeOllamaToolCall(from toolCall: LLMToolCall, logger: Logger) -> OllamaToolCall {
        guard let data = toolCall.arguments.data(using: .utf8) else {
            logger.warning(
                "Ollama tool call arguments were not valid UTF-8; sending empty arguments instead. tool=\(toolCall.name) id=\(toolCall.id)"
            )
            return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: [:]))
        }
        if let arguments = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: arguments))
        }
        if let rawValue = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            logger.warning(
                "Ollama tool call arguments did not decode as a JSON object (e.g. the model emitted an array or scalar); preserving the original value under \"_rawArguments\" instead of substituting {}. tool=\(toolCall.name) id=\(toolCall.id)"
            )
            return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: ["_rawArguments": rawValue]))
        }
        logger.warning(
            "Ollama tool call arguments failed to decode as JSON at all; sending empty arguments instead. tool=\(toolCall.name) id=\(toolCall.id)"
        )
        return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: [:]))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: container.decode(String.self, forKey: .role),
            content: container.decode(String.self, forKey: .content),
            images: container.decodeIfPresent([String].self, forKey: .images),
            thinking: Self.decodeThinking(from: decoder),
            toolCalls: container.decodeIfPresent([OllamaToolCall].self, forKey: .toolCalls)
        )
    }

    /// Decodes the reasoning field, preferring the canonical `thinking` key and falling back to
    /// the legacy `think` key some Ollama-compatible runtimes emit.
    private static func decodeThinking(from decoder: Decoder) -> String? {
        struct AnyCodingKey: CodingKey {
            var stringValue: String
            init(stringValue: String) {
                self.stringValue = stringValue
            }

            var intValue: Int? {
                nil
            }

            init?(intValue _: Int) {
                return nil
            }
        }
        guard let container = try? decoder.container(keyedBy: AnyCodingKey.self) else { return nil }
        if let thinking = try? container.decodeIfPresent(String.self, forKey: .init(stringValue: "thinking")) {
            return thinking
        }
        if let think = try? container.decodeIfPresent(String.self, forKey: .init(stringValue: "think")) {
            return think
        }
        return nil
    }
}

struct OllamaToolCall: Codable {
    let function: OllamaToolCallFunction
}

struct OllamaToolCallFunction: Codable {
    let name: String
    let arguments: [String: AnyCodable]
}

struct OllamaChatResponse: Codable {
    let model: String
    let createdAt: String?
    let message: OllamaMessage
    let done: Bool
    /// Ollama's own completion-reason signal (PKR-13), only meaningful when `done == true`.
    /// Observed wire values include `"stop"` (natural stop) and `"length"` (the response was
    /// truncated because `num_predict`/context limits were hit). Previously undecoded, so a
    /// truncated response was indistinguishable from a normal stop once `finishReason` was
    /// synthesized in `OllamaClient.buildFinalChunk`.
    let doneReason: String?
    let totalDuration: Int64?
    let loadDuration: Int64?
    let promptEvalCount: Int?
    let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
        case doneReason = "done_reason"
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

extension OllamaTool {
    init(from tool: LLMToolDefinition) {
        self.init(
            type: "function",
            function: OllamaToolFunction(
                name: tool.name,
                description: tool.description ?? "",
                parameters: tool.parameters ?? makeEmptyObjectSchema()
            )
        )
    }
}

struct OllamaEndpoint {
    let rawValue: String

    var url: URL? {
        var cleanEndpoint = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.isEmpty {
            return URL(string: "http://localhost:11434")
        }
        if cleanEndpoint.hasSuffix("/") { cleanEndpoint.removeLast() }
        if cleanEndpoint.hasSuffix("/api") { cleanEndpoint.removeLast(4) }

        guard let url = URL(string: cleanEndpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        return url
    }

    var chatURL: URL? {
        url?.appendingPathComponent("api/chat")
    }

    var tagsURL: URL? {
        url?.appendingPathComponent("api/tags")
    }
}
