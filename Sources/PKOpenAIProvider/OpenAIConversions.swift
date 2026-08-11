import Foundation
import struct JSONSchema.Schema
import Logging
import OpenAI
import PKShared
import PKUtilities

/// Retained for source compatibility with the previous conversion logging hook. Invalid tool
/// result history is now rejected with `LLMMessageValidationError` instead of logged and sent.
public let openAIConversionLogger = Logger.module(named: "openai-message-conversion")

public extension LLMToolDefinition {
    func toOpenAIToolParam() -> ChatQuery.ChatCompletionToolParam {
        .init(function: .init(
            name: name,
            description: description,
            parameters: parameters.flatMap { convertToOpenAISchema($0) },
            strict: strict
        ))
    }
}

public extension LLMMessage {
    func toOpenAIMessageParam(logger _: Logger = openAIConversionLogger) throws -> ChatQuery.ChatCompletionMessageParam {
        switch role {
        case .system:
            return .system(.init(content: .textContent(content), name: name))
        case .user:
            if messageContent.isTextOnly {
                return .user(.init(content: .string(content), name: name))
            }
            let parts = try messageContent.parts.map { part -> ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart in
                switch part {
                case let .text(text):
                    return .text(.init(text: text))
                case let .image(image):
                    let detail: ChatQuery.ChatCompletionMessageParam.ContentPartImageParam.ImageURL.Detail? = switch image.detail {
                    case .automatic: .auto
                    case .low: .low
                    case .high: .high
                    case nil: nil
                    }
                    return .image(.init(imageUrl: .init(
                        url: "data:\(image.mediaType);base64,\(image.data.base64EncodedString())",
                        detail: detail
                    )))
                case let .audio(audio):
                    let format: ChatQuery.ChatCompletionMessageParam.ContentPartAudioParam.InputAudio.Format = switch audio.format {
                    case .wav: .wav
                    case .mp3: .mp3
                    default: throw MultimodalContentError.unsupportedAudioFormat(audio.format, provider: .openAI)
                    }
                    return .audio(.init(inputAudio: .init(data: audio.data, format: format)))
                }
            }
            return .user(.init(content: .contentParts(parts), name: name))
        case .assistant:
            // OpenAI `/chat/completions` has no reasoning-echo message field: o-series models
            // continue reasoning via the Responses API (`previous_response_id`), not via an
            // input `reasoning` field on history messages. The openai-swift `AssistantMessageParam`
            // exposes no such parameter either. So `reasoning` is intentionally NOT threaded
            // here (STAB-8); it stays on `LLMMessage.reasoning` for Ollama/OpenRouter only.
            // Sending an unknown `reasoning` field could trip strict validation, so omit entirely.
            let toolCalls = toolCalls?.map {
                ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                    id: $0.id,
                    function: .init(arguments: $0.arguments, name: $0.name)
                )
            }
            let continuation = messageContent.parts.compactMap { part -> AudioContinuationReference? in
                guard case let .audio(audio) = part else { return nil }
                return audio.continuation
            }.first(where: { $0.provider == .openAI && $0.isValid() })
            return .assistant(.init(
                content: content.isEmpty ? nil : .textContent(content),
                audio: continuation.map { .init(id: $0.id) },
                name: name,
                toolCalls: toolCalls
            ))
        case .tool:
            guard let toolCallID, !toolCallID.isEmpty else {
                throw LLMMessageValidationError.missingToolCallID
            }
            return .tool(.init(content: .textContent(content), toolCallId: toolCallID))
        case .developer:
            return .developer(.init(content: .textContent(content), name: name))
        }
    }
}

public extension LLMToolChoice {
    func toOpenAIToolChoice() -> ChatQuery.ChatCompletionFunctionCallOptionParam {
        switch self {
        case .none:
            return .none
        case .auto:
            return .auto
        case let .function(name):
            return .function(name)
        }
    }
}

public extension LLMResponseFormat {
    func toOpenAIResponseFormat() -> ChatQuery.ResponseFormat {
        switch self {
        case .text:
            return .text
        case .jsonObject:
            return .jsonObject
        case let .jsonSchema(schema):
            return .jsonSchema(.init(
                name: schema.name,
                description: schema.description,
                schema: schema.schema.flatMap { convertToOpenAISchema($0) }.map { .jsonSchema($0) },
                strict: schema.strict
            ))
        }
    }
}

extension ChatStreamResult {
    func toLLMStreamChunk(audioFormat: AudioFormat? = nil) -> LLMStreamChunk {
        let mappedChoices: [LLMStreamChoice] = choices.map { choice in
            let mappedToolCalls = choice.delta.toolCalls?.map {
                LLMToolCallDelta(
                    index: $0.index,
                    id: $0.id,
                    function: LLMToolCallDeltaFunction(
                        name: $0.function?.name,
                        arguments: $0.function?.arguments
                    )
                )
            }

            let audioDelta: LLMAudioDelta? = choice.delta.audio.flatMap { audio in
                guard let audioFormat else { return nil }
                let data = audio.data.flatMap { Data(base64Encoded: $0) } ?? Data()
                let continuation: AudioContinuationReference? = if let id = audio.id, let expiresAt = audio.expiresAt {
                    .init(provider: .openAI, id: id, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt)))
                } else { nil }
                return LLMAudioDelta(data: data, format: audioFormat, transcript: audio.transcript, continuation: continuation)
            }
            return LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(
                    role: choice.delta.role.flatMap(mapRole),
                    content: choice.delta.content,
                    reasoning: choice.delta.reasoning,
                    audio: audioDelta,
                    toolCalls: mappedToolCalls
                ),
                finishReason: choice.finishReason.map { mapFinishReason($0).wireValue }
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

extension ChatResult {
    func toLLMToolCallRecoveryChunk() -> LLMStreamChunk? {
        guard let choice = choices.first else { return nil }
        guard choice.finishReason == ChatResult.Choice.FinishReason.toolCalls.rawValue else { return nil }
        guard let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty else { return nil }

        let mappedToolCalls = toolCalls.enumerated().map { index, call in
            LLMToolCallDelta(
                index: index,
                id: call.id,
                function: LLMToolCallDeltaFunction(
                    name: call.function.name,
                    arguments: call.function.arguments
                )
            )
        }

        return LLMStreamChunk(
            id: id,
            model: model,
            choices: [LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: choice.message.content,
                    reasoning: choice.message.reasoning,
                    toolCalls: mappedToolCalls
                ),
                finishReason: FinishReason(wireValue: choice.finishReason).wireValue
            )],
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

private func convertToOpenAISchema(_ schema: Schema) -> JSONSchema? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(schema) else { return nil }
    return try? JSONDecoder().decode(JSONSchema.self, from: data)
}

private func mapFinishReason(_ reason: ChatStreamResult.Choice.FinishReason) -> FinishReason {
    switch reason {
    case .stop:
        return .stop
    case .length:
        return .length
    case .toolCalls:
        return .toolCalls
    case .contentFilter:
        return .contentFilter
    case .functionCall:
        return .other(reason.rawValue)
    case .error:
        return .other(reason.rawValue)
    @unknown default:
        return .other(reason.rawValue)
    }
}

private func mapRole(_ role: ChatQuery.ChatCompletionMessageParam.Role) -> LLMMessage.Role? {
    switch role {
    case .assistant:
        return .assistant
    case .developer:
        return .developer
    case .system:
        return .system
    case .tool:
        return .tool
    case .user:
        return .user
    }
}
