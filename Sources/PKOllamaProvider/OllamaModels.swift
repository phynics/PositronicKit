import Foundation
import struct JSONSchema.Schema
import PKShared

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
        case .jsonSchema(let schema):
            try container.encode(schema)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "json" {
            self = .jsonObject
            return
        }
        self = .jsonSchema(try container.decode(Schema.self))
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
    let toolCalls: [OllamaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
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
    let totalDuration: Int64?
    let loadDuration: Int64?
    let promptEvalCount: Int?
    let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

extension OllamaMessage {
    init(from param: LLMMessage) {
        let role = param.role == .developer ? "system" : param.role.rawValue
        self.init(
            role: role,
            content: param.content,
            toolCalls: param.toolCalls?.compactMap { toolCall in
                guard let data = toolCall.arguments.data(using: .utf8),
                      let arguments = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
                else {
                    return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: [:]))
                }
                return OllamaToolCall(function: OllamaToolCallFunction(name: toolCall.name, arguments: arguments))
            }
        )
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

    var url: URL {
        var cleanEndpoint = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.hasSuffix("/") { cleanEndpoint.removeLast() }
        if cleanEndpoint.hasSuffix("/api") { cleanEndpoint.removeLast(4) }
        return URL(string: cleanEndpoint) ?? URL(string: "http://localhost:11434")!
    }

    var chatURL: URL { url.appendingPathComponent("api/chat") }
    var tagsURL: URL { url.appendingPathComponent("api/tags") }
}
