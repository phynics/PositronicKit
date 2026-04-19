import Foundation
import enum OpenAI.JSONSchema
import OpenAI
import PKShared

public extension LLMServiceProtocol {
    func sendStructuredMessage(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false
    ) async throws -> String {
        let stream = await chatStream(
            messages: [.user(.init(content: .string(content), name: nil))],
            tools: nil,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            useUtilityModel: useUtilityModel
        )

        var content = ""
        for try await result in stream {
            if let delta = result.choices.first?.delta.content {
                content += delta
            }
        }
        return content
    }

    func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]? = nil,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false,
        useFastModel: Bool = false
    ) async -> AsyncThrowingStream<ChatStreamResult, Error> {
        let provider = await configuration.provider
        let prepared = StructuredOutputExecution.prepareStreamRequest(
            messages: messages,
            tools: tools,
            provider: provider,
            output: structuredOutput
        )

        let stream = await chatStream(
            messages: prepared.messages,
            tools: prepared.tools,
            toolChoice: prepared.toolChoice,
            responseFormat: prepared.responseFormat,
            generationParameters: generationParameters,
            useUtilityModel: useUtilityModel,
            useFastModel: useFastModel
        )

        guard let syntheticToolName = prepared.syntheticToolName else {
            return stream
        }

        return StructuredOutputExecution.rewriteSyntheticToolStream(stream, syntheticToolName: syntheticToolName)
    }

    func sendStructured<T: Decodable & Sendable>(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        as type: T.Type = T.self,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false
    ) async throws -> T {
        let response = try await sendStructuredMessage(
            content,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            useUtilityModel: useUtilityModel
        )

        return try StructuredOutputDecoder.decode(type, from: response, decoder: decoder)
    }
}

enum StructuredOutputExecution {
    private static let syntheticToolName = "emit_structured_response"

    struct PreparedMessages {
        let messages: [ChatQuery.ChatCompletionMessageParam]
        let rawPrompt: String
        let responseFormat: ChatQuery.ResponseFormat?
    }

    static func apply(
        to messages: [ChatQuery.ChatCompletionMessageParam],
        rawPrompt: String,
        provider: LLMProvider,
        output: StructuredOutputRequest
    ) -> PreparedMessages {
        let prepared = prepare(for: provider, output: output)
        guard let augmentation = prepared.promptAugmentation else {
            return PreparedMessages(
                messages: messages,
                rawPrompt: rawPrompt,
                responseFormat: prepared.responseFormat
            )
        }

        return PreparedMessages(
            messages: applyPromptAugmentation(augmentation, to: messages),
            rawPrompt: rawPrompt + augmentation,
            responseFormat: prepared.responseFormat
        )
    }

    private struct PreparedRequest {
        let responseFormat: ChatQuery.ResponseFormat?
        let promptAugmentation: String?
    }

    struct StreamRequest {
        let messages: [ChatQuery.ChatCompletionMessageParam]
        let tools: [ChatQuery.ChatCompletionToolParam]?
        let toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?
        let responseFormat: ChatQuery.ResponseFormat?
        let syntheticToolName: String?
    }

    private static func prepare(
        for provider: LLMProvider,
        output: StructuredOutputRequest
    ) -> PreparedRequest {
        switch output {
        case .jsonObject:
            return PreparedRequest(responseFormat: .jsonObject, promptAugmentation: nil)
        case .jsonSchema(let schema):
            switch provider {
            case .openAI, .openRouter:
                let jsonSchema: JSONSchema?
                if let data = try? JSONEncoder().encode(schema.schema) {
                    jsonSchema = try? JSONDecoder().decode(JSONSchema.self, from: data)
                } else {
                    jsonSchema = nil
                }

                return PreparedRequest(
                    responseFormat: .jsonSchema(.init(
                        name: schema.name,
                        description: schema.description,
                        schema: jsonSchema.map { .jsonSchema($0) },
                        strict: schema.strict
                    )),
                    promptAugmentation: nil
                )
            case .ollama, .openAICompatible:
                if provider == .openAICompatible {
                    return PreparedRequest(responseFormat: nil, promptAugmentation: nil)
                }
                return PreparedRequest(responseFormat: .jsonObject, promptAugmentation: fallbackPromptSuffix(schema: schema))
            }
        }
    }

    static func prepareStreamRequest(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        provider: LLMProvider,
        output: StructuredOutputRequest
    ) -> StreamRequest {
        switch output {
        case .jsonObject:
            return StreamRequest(
                messages: messages,
                tools: tools,
                toolChoice: nil,
                responseFormat: .jsonObject,
                syntheticToolName: nil
            )
        case .jsonSchema(let schema):
            switch provider {
            case .openAI, .openRouter:
                let prepared = prepare(for: provider, output: output)
                return StreamRequest(
                    messages: messages,
                    tools: tools,
                    toolChoice: nil,
                    responseFormat: prepared.responseFormat,
                    syntheticToolName: nil
                )
            case .ollama:
                let augmentation = fallbackPromptSuffix(schema: schema)
                return StreamRequest(
                    messages: applyPromptAugmentation(augmentation, to: messages),
                    tools: tools,
                    toolChoice: nil,
                    responseFormat: .jsonObject,
                    syntheticToolName: nil
                )
            case .openAICompatible:
                let syntheticTool = syntheticTool(for: schema)
                return StreamRequest(
                    messages: messages,
                    tools: (tools ?? []) + [syntheticTool],
                    toolChoice: .function(syntheticToolName),
                    responseFormat: nil,
                    syntheticToolName: syntheticToolName
                )
            }
        }
    }

    private static func fallbackPromptSuffix(schema: StructuredOutputSchema) -> String {
        let schemaString: String
        if let data = try? JSONEncoder().encode(schema.schema) {
            schemaString = String(decoding: data, as: UTF8.self)
        } else {
            schemaString = "{}"
        }
        return """

        Return ONLY valid JSON that matches this JSON Schema exactly.
        Schema name: \(schema.name)
        JSON Schema:
        \(schemaString)
        """
    }

    private static func applyPromptAugmentation(
        _ augmentation: String,
        to messages: [ChatQuery.ChatCompletionMessageParam]
    ) -> [ChatQuery.ChatCompletionMessageParam] {
        var updatedMessages = messages

        for index in updatedMessages.indices.reversed() {
            guard case let .user(message) = updatedMessages[index] else { continue }
            guard case let .string(content) = message.content else { continue }

            updatedMessages[index] = .user(.init(content: .string(content + augmentation), name: message.name))
            return updatedMessages
        }

        updatedMessages.append(.user(.init(content: .string(augmentation.trimmingCharacters(in: .whitespacesAndNewlines)), name: nil)))
        return updatedMessages
    }

    private static func syntheticTool(for schema: StructuredOutputSchema) -> ChatQuery.ChatCompletionToolParam {
        let parameters: JSONSchema?
        if let data = try? JSONEncoder().encode(schema.schema) {
            parameters = try? JSONDecoder().decode(JSONSchema.self, from: data)
        } else {
            parameters = nil
        }

        return .init(function: .init(
            name: syntheticToolName,
            description: schema.description ?? "Emit the final structured response payload for \(schema.name).",
            parameters: parameters,
            strict: schema.strict
        ))
    }

    static func rewriteSyntheticToolStream(
        _ stream: AsyncThrowingStream<ChatStreamResult, Error>,
        syntheticToolName: String
    ) -> AsyncThrowingStream<ChatStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in stream {
                        if let rewritten = rewriteSyntheticToolChunk(result, syntheticToolName: syntheticToolName) {
                            continuation.yield(rewritten)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func rewriteSyntheticToolChunk(
        _ result: ChatStreamResult,
        syntheticToolName: String
    ) -> ChatStreamResult? {
        guard let choice = result.choices.first else { return result }
        let toolCalls = choice.delta.toolCalls ?? []
        let syntheticCalls = toolCalls.filter { $0.function?.name == syntheticToolName }

        guard !syntheticCalls.isEmpty else { return result }

        let contentParts = syntheticCalls.compactMap { $0.function?.arguments }.filter { !$0.isEmpty }
        let mergedContent = contentParts.joined()

        guard !mergedContent.isEmpty else { return nil }

        var choiceDict: [String: Any] = [
            "index": choice.index,
            "delta": ["role": "assistant", "content": mergedContent]
        ]
        if let finishReason = choice.finishReason {
            choiceDict["finish_reason"] = finishReason.rawValue
        }

        let jsonDict: [String: Any] = [
            "id": result.id,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": result.model,
            "choices": [choiceDict]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: jsonDict) else {
            return nil
        }

        return try? JSONDecoder().decode(ChatStreamResult.self, from: data)
    }
}
