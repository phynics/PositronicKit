import Foundation
import PKShared
import OpenAI

// MARK: - API Models

struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let format: String?
    let tools: [OllamaTool]?
    let options: OllamaOptions?
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
        // Ollama's repeat_penalty differs from OpenAI's frequency_penalty but is the closest approximation
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
    let parameters: JSONSchema
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

// MARK: - Helper Constructs

extension OllamaMessage {
    init(from param: ChatQuery.ChatCompletionMessageParam) {
        let role: String
        switch param {
        case .system: role = "system"
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .tool: role = "tool"
        case .developer: role = "system"
        }

        self.init(role: role, content: Self.extractContent(from: param), toolCalls: nil)
    }

    private static func extractContent(from param: ChatQuery.ChatCompletionMessageParam) -> String {
        switch param {
        case let .system(msg):
            return textFromSystemContent(msg)
        case let .user(msg):
            return textFromUserContent(msg)
        case let .assistant(msg):
            return textFromAssistantContent(msg)
        case let .tool(msg):
            return textFromToolContent(msg)
        case let .developer(msg):
            return textFromDeveloperContent(msg)
        }
    }

    private static func textFromSystemContent(
        _ msg: ChatQuery.ChatCompletionMessageParam.SystemMessageParam
    ) -> String {
        if case let .textContent(text) = msg.content { return text }
        return "\(msg.content)"
    }

    private static func textFromUserContent(
        _ msg: ChatQuery.ChatCompletionMessageParam.UserMessageParam
    ) -> String {
        if case let .string(text) = msg.content { return text }
        return "\(msg.content)"
    }

    private static func textFromAssistantContent(
        _ msg: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
    ) -> String {
        guard let content = msg.content else { return "" }
        if case let .textContent(text) = content { return text }
        return "\(content)"
    }

    private static func textFromToolContent(
        _ msg: ChatQuery.ChatCompletionMessageParam.ToolMessageParam
    ) -> String {
        if case let .textContent(text) = msg.content { return text }
        return "\(msg.content)"
    }

    private static func textFromDeveloperContent(
        _ msg: ChatQuery.ChatCompletionMessageParam.DeveloperMessageParam
    ) -> String {
        if case let .textContent(text) = msg.content { return text }
        return "\(msg.content)"
    }
}

extension OllamaTool {
    init(from tool: ChatQuery.ChatCompletionToolParam) {
        self.init(
            type: "function",
            function: OllamaToolFunction(
                name: tool.function.name,
                description: tool.function.description ?? "",
                parameters: tool.function.parameters ?? .object([:])
            )
        )
    }
}

struct OllamaEndpoint {
    let rawValue: String

    var url: URL {
        var cleanEndpoint = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.hasSuffix("/") {
            cleanEndpoint.removeLast()
        }
        if cleanEndpoint.hasSuffix("/api") {
            cleanEndpoint.removeLast(4)
        }

        if let url = URL(string: cleanEndpoint) {
            return url
        } else {
            return URL(string: "http://localhost:11434")!
        }
    }

    var chatURL: URL {
        url.appendingPathComponent("api/chat")
    }

    var tagsURL: URL {
        url.appendingPathComponent("api/tags")
    }
}
