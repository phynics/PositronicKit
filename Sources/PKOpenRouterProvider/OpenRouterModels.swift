import Foundation
import struct JSONSchema.Schema
import Logging
import PKContracts
import PKUtilities

struct OpenRouterModelsResponse: Codable {
    struct Model: Codable { let id: String }
    let data: [Model]
}

struct OpenRouterChatResponse: Codable {
    struct Choice: Codable {
        let index: Int
        let message: OpenRouterMessage
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    let id: String
    let model: String
    let choices: [Choice]
    let usage: OpenRouterUsage?
}

struct OpenRouterUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenRouterChatRequest: Codable {
    let messages: [OpenRouterMessage]
    let model: String
    let frequencyPenalty: Double?
    let maxCompletionTokens: Int?
    let presencePenalty: Double?
    let responseFormat: OpenRouterResponseFormat?
    let seed: Int?
    let temperature: Double?
    let toolChoice: OpenRouterToolChoice?
    let tools: [OpenRouterTool]?
    let topP: Double?
    let stream: Bool
    let streamOptions: OpenRouterStreamOptions?
    let modalities: [ResponseModality]?
    let audio: AudioOutputOptions?

    enum CodingKeys: String, CodingKey {
        case messages, model, seed, temperature, tools, stream, modalities, audio
        case frequencyPenalty = "frequency_penalty"
        case maxCompletionTokens = "max_completion_tokens"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case streamOptions = "stream_options"
    }
}

struct OpenRouterMessage: Codable {
    let role: String
    let content: OpenRouterMessageContent
    let name: String?
    let toolCallID: String?
    let toolCalls: [OpenRouterToolCall]?
    let audio: OpenRouterAssistantAudio?

    /// Reasoning to echo back to a reasoning model on follow-up turns (STAB-8). OpenRouter
    /// accepts a `reasoning` field on assistant history messages for reasoning models
    /// (https://openrouter.ai/docs#reasoning-models). Sourced from `LLMMessage.reasoning`
    /// (which is itself threaded from persisted `Message.think`). When `nil`, synthesis uses
    /// `encodeIfPresent`, so the key is omitted and non-reasoning request payloads stay
    /// byte-identical.
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning, audio
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    /// - Parameter logger: Used to warn when `message` has `.tool` role but a nil `toolCallID`
    ///   (PKR-12). `LLMMessage.toolCallID` is `String?`, but a `.tool`-role message without one is
    ///   a contract violation: OpenRouter requires `tool_call_id` on tool messages, and an absent
    ///   value only surfaces later as an opaque provider 400.
    init(_ message: LLMMessage, logger: Logger = Logger.module(named: "openrouter-message-conversion")) {
        role = message.role.rawValue
        if message.role == .assistant {
            content = .text(message.content)
            audio = message.messageContent.parts.compactMap { part -> AudioContinuationReference? in
                guard case let .audio(value) = part else { return nil }
                return value.continuation
            }.first(where: { $0.provider == .openRouter && $0.isValid() }).map {
                OpenRouterAssistantAudio(id: $0.id)
            }
        } else {
            content = message.messageContent.isTextOnly
                ? .text(message.content)
                : .parts(message.messageContent.parts.map(OpenRouterContentPart.init))
            audio = nil
        }
        name = message.name
        toolCallID = message.toolCallID
        toolCalls = message.toolCalls?.map(OpenRouterToolCall.init)
        reasoning = message.reasoning

        if message.role == .tool, message.toolCallID == nil {
            logger.warning(
                "LLMMessage with .tool role is missing toolCallID (contract violation); sending a nil tool_call_id to OpenRouter, which will likely surface as a 400."
            )
        }
    }
}

struct OpenRouterAssistantAudio: Codable {
    let id: String
}

enum OpenRouterMessageContent: Codable {
    case text(String)
    case parts([OpenRouterContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .parts(try container.decode([OpenRouterContentPart].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text): try container.encode(text)
        case let .parts(parts): try container.encode(parts)
        }
    }

    var text: String {
        switch self {
        case let .text(text): text
        case let .parts(parts): parts.compactMap { part in
            guard case let .text(text) = part else { return nil }
            return text
        }.joined()
        }
    }
}

enum OpenRouterContentPart: Codable {
    case text(String)
    case image(ImageContent)
    case audio(AudioContent)

    private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url", inputAudio = "input_audio" }
    private struct ImageURL: Codable { let url: String; let detail: String? }
    private struct InputAudio: Codable { let data: String; let format: String }

    init(_ part: MessageContentPart) {
        switch part {
        case let .text(text): self = .text(text)
        case let .image(image): self = .image(image)
        case let .audio(audio): self = .audio(audio)
        }
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct OpenRouterToolCall: Codable {
    let id: String
    let type: String
    let function: OpenRouterToolCallFunction

    init(_ call: LLMToolCall) {
        id = call.id
        type = "function"
        function = .init(name: call.name, arguments: call.arguments)
    }
}

struct OpenRouterToolCallFunction: Codable {
    let name: String
    let arguments: String
}

struct OpenRouterTool: Codable {
    let type: String
    let function: OpenRouterToolDefinition

    init(_ tool: LLMToolDefinition) {
        type = "function"
        function = .init(name: tool.name, description: tool.description, parameters: tool.parameters, strict: tool.strict)
    }
}

struct OpenRouterToolDefinition: Codable {
    let name: String
    let description: String?
    let parameters: Schema?
    let strict: Bool?
}

enum OpenRouterToolChoice: Codable {
    case none
    case auto
    case function(String)

    private struct FunctionWrapper: Codable {
        let type: String
        let function: NamedFunction
    }

    private struct NamedFunction: Codable { let name: String }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        case .auto:
            try container.encode("auto")
        case let .function(name):
            try container.encode(FunctionWrapper(type: "function", function: NamedFunction(name: name)))
        }
    }
}

enum OpenRouterResponseFormat: Codable {
    case jsonObject
    case jsonSchema(OpenRouterResponseSchema)

    private struct KindOnly: Codable { let type: String }

    private struct SchemaWrapper: Codable {
        let type: String
        let jsonSchema: OpenRouterResponseSchema

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .jsonObject:
            try container.encode(KindOnly(type: "json_object"))
        case let .jsonSchema(schema):
            try container.encode(SchemaWrapper(type: "json_schema", jsonSchema: schema))
        }
    }
}

struct OpenRouterResponseSchema: Codable {
    let name: String
    let description: String?
    let schema: Schema?
    let strict: Bool?
}

struct OpenRouterStreamOptions: Codable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

/// Provider-specific mirror of the OpenAI/OpenRouter streaming chunk DTO.
///
/// OpenRouter's wire format is snake_case (`tool_calls`, `finish_reason`, `prompt_tokens`) and,
/// for reasoning models, surfaces reasoning via `delta.reasoning` (their canonical field — see
/// https://openrouter.ai/docs#reasoning-models). The transport-neutral `LLMStreamChunk` uses
/// camelCase with no explicit CodingKeys and is decoded via `.convertFromSnakeCase`, so a
/// `reasoning` wire field would not match a neutral `thinking` property. Decoding into this
/// intermediate DTO lets us capture `reasoning` explicitly and map it onto
/// `LLMStreamDelta.thinking` during conversion, keeping the neutral type provider-agnostic.
struct OpenRouterStreamChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let role: String?
            let content: String?
            let reasoning: String?
            let toolCalls: [OpenRouterStreamToolCall]?
            let audio: Audio?

            struct Audio: Codable {
                let data: String?
                let transcript: String?
                let id: String?
                let expiresAt: Int?
                enum CodingKeys: String, CodingKey { case data, transcript, id; case expiresAt = "expires_at" }
            }
        }

        let index: Int
        let delta: Delta
        let finishReason: String?
    }

    struct Usage: Codable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        struct PromptTokensDetails: Codable {
            let cachedTokens: Int?
        }
    }

    struct OpenRouterStreamToolCall: Codable {
        let index: Int?
        let id: String?
        let function: Function

        struct Function: Codable {
            let name: String?
            let arguments: String?
        }
    }

    let id: String
    let model: String
    let choices: [Choice]
    let usage: Usage?
}

extension OpenRouterStreamChunk {
    /// Converts the provider-specific chunk into the transport-neutral `LLMStreamChunk`,
    /// mapping `delta.reasoning` → `LLMStreamDelta.thinking`.
    func toLLMStreamChunk(audioFormat: AudioFormat? = nil) -> LLMStreamChunk {
        let mappedChoices: [LLMStreamChoice] = choices.map { choice in
            let mappedToolCalls = choice.delta.toolCalls?.map {
                LLMToolCallDelta(
                    index: $0.index,
                    id: $0.id,
                    function: LLMToolCallDeltaFunction(
                        name: $0.function.name,
                        arguments: $0.function.arguments
                    )
                )
            }
            return LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(
                    role: choice.delta.role.flatMap(LLMMessage.Role.init(rawValue:)),
                    content: choice.delta.content,
                    reasoning: choice.delta.reasoning,
                    audio: choice.delta.audio.flatMap { audio -> LLMAudioDelta? in
                        guard let audioFormat else { return nil }
                        let continuation: AudioContinuationReference? = if let id = audio.id, let expiry = audio.expiresAt {
                            .init(provider: .openRouter, id: id, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
                        } else { nil }
                        return .init(
                            data: audio.data.flatMap { Data(base64Encoded: $0) } ?? Data(),
                            format: audioFormat,
                            transcript: audio.transcript,
                            continuation: continuation
                        )
                    },
                    toolCalls: mappedToolCalls
                ),
                finishReason: choice.finishReason.map { FinishReason(wireValue: $0).wireValue }
            )
        }
        return LLMStreamChunk(
            id: id,
            model: model,
            choices: mappedChoices,
            usage: usage.map {
                LLMTokenUsage(
                    promptTokens: $0.promptTokens,
                    completionTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens,
                    promptTokensDetails: .init(cachedTokens: $0.promptTokensDetails?.cachedTokens)
                )
            }
        )
    }
}
