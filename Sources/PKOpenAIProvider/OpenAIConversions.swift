import Foundation
import OpenAI
import PKPrompt
import PKShared
import struct JSONSchema.Schema

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
    func toOpenAIMessageParam() -> ChatQuery.ChatCompletionMessageParam {
        switch role {
        case .system:
            return .system(.init(content: .textContent(content), name: name))
        case .user:
            return .user(.init(content: .string(content), name: name))
        case .assistant:
            let toolCalls = toolCalls?.map {
                ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                    id: $0.id,
                    function: .init(arguments: $0.arguments, name: $0.name)
                )
            }
            return .assistant(.init(content: .textContent(content), name: name, toolCalls: toolCalls))
        case .tool:
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
        case .function(let name):
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
        case .jsonSchema(let schema):
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
                finishReason: choice.finishReason?.rawValue
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
                finishReason: choice.finishReason
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
    guard let data = try? JSONEncoder().encode(schema) else { return nil }
    return try? JSONDecoder().decode(JSONSchema.self, from: data)
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
