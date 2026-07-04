import Foundation
import struct JSONSchema.Schema
import Logging
import OpenAI
import PKPrompt
import PKShared

/// Logger used when an `LLMMessage` with `.tool` role is converted for the OpenAI wire format
/// without a `toolCallID` (PKR-12). `LLMMessage.toolCallID` is `String?`, but a `.tool`-role
/// message without one is a contract violation: OpenAI requires `tool_call_id` on tool messages,
/// and silently substituting `""` only surfaces later as an opaque provider 400.
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
    func toOpenAIMessageParam(logger: Logger = openAIConversionLogger) -> ChatQuery.ChatCompletionMessageParam {
        switch role {
        case .system:
            return .system(.init(content: .textContent(content), name: name))
        case .user:
            return .user(.init(content: .string(content), name: name))
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
            return .assistant(.init(content: .textContent(content), name: name, toolCalls: toolCalls))
        case .tool:
            if toolCallID == nil {
                logger.warning(
                    "LLMMessage with .tool role is missing toolCallID (contract violation); sending empty tool_call_id to OpenAI, which will likely surface as a 400."
                )
            }
            return .tool(.init(content: .textContent(content), toolCallId: toolCallID ?? ""))
        case .developer:
            return .developer(.init(content: .textContent(content), name: name))
        }
    }
}

public extension LLMToolChoice {
    func toOpenAIToolChoice() -> ChatQuery.ChatCompletionFunctionCallOptionParam {
        switch self {
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
    func toLLMStreamChunk() -> LLMStreamChunk {
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

            return LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(
                    role: choice.delta.role.flatMap(mapRole),
                    content: choice.delta.content,
                    thinking: choice.delta.reasoning,
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
                    thinking: choice.message.reasoning,
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

public extension RenderedPrompt {
    func buildOpenAIMessages() -> [ChatQuery.ChatCompletionMessageParam] {
        buildMessages().map { $0.toOpenAIMessageParam() }
    }
}

public extension PKShared.Tool {
    func toOpenAIToolParam() -> ChatQuery.ChatCompletionToolParam {
        toLLMToolDefinition().toOpenAIToolParam()
    }
}
