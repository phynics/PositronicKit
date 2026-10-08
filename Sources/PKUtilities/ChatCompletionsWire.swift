import Foundation
import struct JSONSchema.Schema
import Logging
import PKContracts
import Synchronization

// MARK: - Shared OpenAI-compatible Chat Completions wire format
//
// Generalized from OpenRouterModels.swift. Both PKOpenAIProvider (Chat Completions path)
// and PKOpenRouterProvider build on these types. All request bodies are encoded with
// `.sortedKeys` for deterministic bytes.

package struct ChatCompletionsUsage: Codable, Sendable {
    package let promptTokens: Int?
    package let completionTokens: Int?
    package let totalTokens: Int?
    package let promptTokensDetails: PromptTokensDetails?
    package let cacheDiscount: Double?

    package struct PromptTokensDetails: Codable, Sendable {
        package let cachedTokens: Int?
        package let cacheWriteTokens: Int?

        package enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }

    package enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case cacheDiscount = "cache_discount"
    }

    package func toLLMTokenUsage() -> LLMTokenUsage {
        LLMTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            promptTokensDetails: .init(cachedTokens: promptTokensDetails?.cachedTokens)
        )
    }
}

package struct ChatCompletionsChatRequest: Codable, Sendable {
    package var messages: [ChatCompletionsMessage]
    package var model: String
    package var frequencyPenalty: Double?
    package var maxCompletionTokens: Int?
    package var presencePenalty: Double?
    package var responseFormat: ChatCompletionsResponseFormat?
    package var seed: Int?
    package var temperature: Double?
    package var toolChoice: ChatCompletionsToolChoice?
    package var tools: [ChatCompletionsTool]?
    package var topP: Double?
    package var stream: Bool
    package var streamOptions: ChatCompletionsStreamOptions?
    package var modalities: [ResponseModality]?
    package var audio: AudioOutputOptions?
    package var sessionID: String?

    package init(
        messages: [ChatCompletionsMessage], model: String,
        frequencyPenalty: Double? = nil, maxCompletionTokens: Int? = nil,
        presencePenalty: Double? = nil, responseFormat: ChatCompletionsResponseFormat? = nil,
        seed: Int? = nil, temperature: Double? = nil,
        toolChoice: ChatCompletionsToolChoice? = nil, tools: [ChatCompletionsTool]? = nil,
        topP: Double? = nil, stream: Bool, streamOptions: ChatCompletionsStreamOptions? = nil,
        modalities: [ResponseModality]? = nil, audio: AudioOutputOptions? = nil,
        sessionID: String? = nil
    ) {
        self.messages = messages; self.model = model
        self.frequencyPenalty = frequencyPenalty; self.maxCompletionTokens = maxCompletionTokens
        self.presencePenalty = presencePenalty; self.responseFormat = responseFormat
        self.seed = seed; self.temperature = temperature
        self.toolChoice = toolChoice; self.tools = tools; self.topP = topP
        self.stream = stream; self.streamOptions = streamOptions
        self.modalities = modalities; self.audio = audio; self.sessionID = sessionID
    }

    package enum CodingKeys: String, CodingKey {
        case messages, model, seed, temperature, tools, stream, modalities, audio
        case frequencyPenalty = "frequency_penalty"
        case maxCompletionTokens = "max_completion_tokens"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case streamOptions = "stream_options"
        case sessionID = "session_id"
    }
}

package struct ChatCompletionsMessage: Codable, Sendable {
    package let role: String
    package let content: ChatCompletionsMessageContent?
    package let name: String?
    package let toolCallID: String?
    package let toolCalls: [ChatCompletionsToolCall]?
    package let audio: ChatCompletionsAssistantAudio?
    package let reasoning: String?

    package enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning, audio
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    package init(_ message: LLMMessage, provider: LLMProvider = .openRouter, logger: Logger = Logger.module(named: "chat-completions-wire")) {
        role = message.role.rawValue
        if message.role == .assistant {
            content = .text(message.content)
            audio = message.messageContent.parts.compactMap { part -> AudioContinuationReference? in
                guard case let .audio(value) = part else { return nil }
                return value.continuation
            }.first(where: { $0.provider == provider && $0.isValid() }).map {
                ChatCompletionsAssistantAudio(id: $0.id)
            }
        } else {
            content = message.messageContent.isTextOnly
                ? .text(message.content)
                : .parts(message.messageContent.parts.map(ChatCompletionsContentPart.init))
            audio = nil
        }
        name = message.name
        toolCallID = message.toolCallID
        toolCalls = message.toolCalls?.map(ChatCompletionsToolCall.init)
        reasoning = message.reasoning
        if message.role == .tool, message.toolCallID == nil {
            logger.warning("LLMMessage with .tool role is missing toolCallID (contract violation).")
        }
    }

    package init(role: String, content: ChatCompletionsMessageContent? = nil, name: String? = nil, toolCallID: String? = nil, toolCalls: [ChatCompletionsToolCall]? = nil, audio: ChatCompletionsAssistantAudio? = nil, reasoning: String? = nil) {
        self.role = role; self.content = content; self.name = name
        self.toolCallID = toolCallID; self.toolCalls = toolCalls
        self.audio = audio; self.reasoning = reasoning
    }
}

package struct ChatCompletionsAssistantAudio: Codable, Sendable {
    package let id: String
    package var data: String?
    package var transcript: String?
    package var expiresAt: Int?

    package enum CodingKeys: String, CodingKey {
        case id, data, transcript
        case expiresAt = "expires_at"
    }
}

package enum ChatCompletionsMessageContent: Codable, Sendable {
    case text(String)
    case parts([ChatCompletionsContentPart])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) } else {
            self = .parts(try container.decode([ChatCompletionsContentPart].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text): try container.encode(text)
        case let .parts(parts): try container.encode(parts)
        }
    }

    package var text: String {
        switch self {
        case let .text(text): text
        case let .parts(parts): parts.compactMap { part in
            guard case let .text(text) = part else { return nil }
            return text
        }.joined()
        }
    }
}

package enum ChatCompletionsContentPart: Codable, Sendable {
    case text(String)
    case image(ImageContent)
    case audio(AudioContent)

    private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url", inputAudio = "input_audio" }
    private struct ImageURL: Codable { let url: String; let detail: String? }
    private struct InputAudio: Codable { let data: String; let format: String }

    package init(_ part: MessageContentPart) {
        switch part {
        case let .text(text): self = .text(text)
        case let .image(image): self = .image(image)
        case let .audio(audio): self = .audio(audio)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            let value = try container.decode(ImageURL.self, forKey: .imageURL)
            guard let separator = value.url.range(of: ";base64,") else { throw DecodingError.dataCorruptedError(forKey: .imageURL, in: container, debugDescription: "Expected image data URL") }
            let mediaType = String(value.url[value.url.index(value.url.startIndex, offsetBy: 5)..<separator.lowerBound])
            let data = Data(base64Encoded: String(value.url[separator.upperBound...])) ?? Data()
            self = .image(.init(data: data, mediaType: mediaType, detail: value.detail.flatMap { ImageDetail(rawValue: $0 == "auto" ? "automatic" : $0) }))
        case "input_audio":
            let value = try container.decode(InputAudio.self, forKey: .inputAudio)
            self = .audio(.init(data: Data(base64Encoded: value.data) ?? Data(), format: AudioFormat(rawValue: value.format) ?? .wav))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content part")
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type); try container.encode(text, forKey: .text)
        case let .image(image):
            try container.encode("image_url", forKey: .type)
            let detail = image.detail.map { $0 == .automatic ? "auto" : $0.rawValue }
            try container.encode(ImageURL(url: "data:\(image.mediaType);base64,\(image.data.base64EncodedString())", detail: detail), forKey: .imageURL)
        case let .audio(audio):
            try container.encode("input_audio", forKey: .type)
            try container.encode(InputAudio(data: audio.data.base64EncodedString(), format: audio.format.rawValue), forKey: .inputAudio)
        }
    }
}

package struct ChatCompletionsToolCall: Codable, Sendable {
    package let id: String
    package let type: String
    package let function: ChatCompletionsToolCallFunction
    package init(_ call: LLMToolCall) {
        id = call.id; type = "function"
        function = .init(name: call.name, arguments: call.arguments)
    }
    package init(id: String, type: String = "function", function: ChatCompletionsToolCallFunction) {
        self.id = id; self.type = type; self.function = function
    }
}

package struct ChatCompletionsToolCallFunction: Codable, Sendable {
    package let name: String
    package let arguments: String
}

package struct ChatCompletionsTool: Codable, Sendable {
    package let type: String
    package let function: ChatCompletionsToolDefinition
    package init(_ tool: LLMToolDefinition) {
        type = "function"
        function = .init(name: tool.name, description: tool.description, parameters: tool.parameters, strict: tool.isStrict)
    }
    package init(type: String = "function", function: ChatCompletionsToolDefinition) {
        self.type = type; self.function = function
    }
}

package struct ChatCompletionsToolDefinition: Codable, Sendable {
    package let name: String
    package let description: String?
    package let parameters: Schema?
    package let strict: Bool?
}

package enum ChatCompletionsToolChoice: Codable, Sendable {
    case none
    case auto
    case function(String)
    private struct FunctionWrapper: Codable { let type: String; let function: NamedFunction }
    private struct NamedFunction: Codable { let name: String }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encode("none")
        case .auto: try container.encode("auto")
        case let .function(name): try container.encode(FunctionWrapper(type: "function", function: NamedFunction(name: name)))
        }
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = s == "none" ? .none : .auto
        } else {
            let w = try container.decode(FunctionWrapper.self)
            self = .function(w.function.name)
        }
    }
}

package enum ChatCompletionsResponseFormat: Codable, Sendable {
    case jsonObject
    case jsonSchema(ChatCompletionsResponseSchema)
    private struct KindOnly: Codable { let type: String }
    private struct SchemaWrapper: Codable {
        let type: String
        let jsonSchema: ChatCompletionsResponseSchema
        enum CodingKeys: String, CodingKey { case type; case jsonSchema = "json_schema" }
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .jsonObject: try container.encode(KindOnly(type: "json_object"))
        case let .jsonSchema(schema): try container.encode(SchemaWrapper(type: "json_schema", jsonSchema: schema))
        }
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let kind = try? container.decode(KindOnly.self), kind.type == "json_object" { self = .jsonObject; return }
        let w = try container.decode(SchemaWrapper.self)
        self = .jsonSchema(w.jsonSchema)
    }
}

package struct ChatCompletionsResponseSchema: Codable, Sendable {
    package let name: String
    package let description: String?
    package let schema: Schema?
    package let strict: Bool?
}

package struct ChatCompletionsStreamOptions: Codable, Sendable {
    package let includeUsage: Bool
    package enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

package struct ChatCompletionsChatResponse: Codable, Sendable {
    package struct Choice: Codable, Sendable {
        package let index: Int
        package let message: ChatCompletionsMessage
        package let finishReason: String?
        package enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }
    package let id: String
    package let model: String
    package let choices: [Choice]
    package let usage: ChatCompletionsUsage?

    package func toLLMStreamChunk(audioFormat: AudioFormat? = nil, continuationProvider: LLMProvider = .openRouter) -> LLMStreamChunk {
        LLMStreamChunk(
            id: id, model: model,
            choices: choices.map { choice in
                let calls = choice.message.toolCalls?.enumerated().map { index, call in
                    LLMToolCallDelta(index: index, id: call.id, function: LLMToolCallDeltaFunction(name: call.function.name, arguments: call.function.arguments))
                }
                return LLMStreamChoice(
                    index: choice.index,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        content: choice.message.content?.text,
                        reasoning: choice.message.reasoning,
                        audio: choice.message.audio.flatMap { audio in
                            guard let audioFormat else { return nil }
                            let continuation: AudioContinuationReference? = audio.expiresAt.map {
                                .init(provider: continuationProvider, id: audio.id, expiresAt: Date(timeIntervalSince1970: TimeInterval($0)))
                            }
                            return LLMAudioDelta(data: audio.data.flatMap { Data(base64Encoded: $0) } ?? Data(), format: audioFormat, transcript: audio.transcript, continuation: continuation)
                        },
                        toolCalls: calls
                    ),
                    finishReason: choice.finishReason.map { FinishReason(wireValue: $0).wireValue }
                )
            },
            usage: usage.map { $0.toLLMTokenUsage() }
        )
    }
}

package struct ChatCompletionsStreamChunk: Codable, Sendable {
    package struct Choice: Codable, Sendable {
        package struct Delta: Codable, Sendable {
            package let role: String?
            package let content: String?
            package let reasoning: String?
            package let toolCalls: [StreamToolCall]?
            package let audio: Audio?
            package struct Audio: Codable, Sendable {
                package let data: String?
                package let transcript: String?
                package let id: String?
                package let expiresAt: Int?
                package enum CodingKeys: String, CodingKey { case data, transcript, id; case expiresAt = "expires_at" }
            }
        }
        package let index: Int
        package let delta: Delta
        package let finishReason: String?
    }
    package struct Usage: Codable, Sendable {
        package let promptTokens: Int?
        package let completionTokens: Int?
        package let totalTokens: Int?
        package let promptTokensDetails: PromptTokensDetails?
        package struct PromptTokensDetails: Codable, Sendable { package let cachedTokens: Int?; package let cacheWriteTokens: Int? }
    }
    package struct StreamToolCall: Codable, Sendable {
        package let index: Int?
        package let id: String?
        package let function: Function
        package struct Function: Codable, Sendable { package let name: String?; package let arguments: String? }
    }
    package let id: String
    package let model: String
    package let choices: [Choice]
    package let usage: Usage?

    package func toLLMStreamChunk(audioFormat: AudioFormat? = nil, continuationProvider: LLMProvider = .openRouter) -> LLMStreamChunk {
        LLMStreamChunk(
            id: id, model: model,
            choices: choices.map { choice in
                LLMStreamChoice(
                    index: choice.index,
                    delta: LLMStreamDelta(
                        role: choice.delta.role.flatMap(LLMMessage.Role.init(rawValue:)),
                        content: choice.delta.content,
                        reasoning: choice.delta.reasoning,
                        audio: choice.delta.audio.flatMap { audio -> LLMAudioDelta? in
                            guard let audioFormat else { return nil }
                            let continuation: AudioContinuationReference? = if let id = audio.id, let expiry = audio.expiresAt {
                                .init(provider: continuationProvider, id: id, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
                            } else { nil }
                            return .init(data: audio.data.flatMap { Data(base64Encoded: $0) } ?? Data(), format: audioFormat, transcript: audio.transcript, continuation: continuation)
                        },
                        toolCalls: choice.delta.toolCalls?.map {
                            LLMToolCallDelta(index: $0.index, id: $0.id, function: LLMToolCallDeltaFunction(name: $0.function.name, arguments: $0.function.arguments))
                        }
                    ),
                    finishReason: choice.finishReason.map { FinishReason(wireValue: $0).wireValue }
                )
            },
            usage: usage.map {
                LLMTokenUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens, totalTokens: $0.totalTokens, promptTokensDetails: .init(cachedTokens: $0.promptTokensDetails?.cachedTokens))
            }
        )
    }
}

// MARK: - Shared helpers

package enum ChatCompletionsWire {
    package static var streamChunkDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    package static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    package static func mapToolChoice(_ choice: LLMToolChoice?, tools: [LLMToolDefinition]?) -> ChatCompletionsToolChoice? {
        switch choice {
        case nil: return tools != nil ? .auto : nil
        case .some(.none): return ChatCompletionsToolChoice.none
        case .some(.auto): return ChatCompletionsToolChoice.auto
        case let .some(.function(name)): return .function(name)
        }
    }

    package static func mapResponseFormat(_ format: LLMResponseFormat?) -> ChatCompletionsResponseFormat? {
        switch format {
        case .none, .text: return nil
        case .jsonObject: return .jsonObject
        case let .jsonSchema(schema): return .jsonSchema(.init(name: schema.name, description: schema.description, schema: schema.schema, strict: schema.isStrict))
        }
    }
}
