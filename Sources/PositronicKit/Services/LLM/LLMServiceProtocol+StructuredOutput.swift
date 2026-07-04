import Foundation
import struct JSONSchema.Schema
import PKShared

public extension LLMServiceProtocol {
    func sendStructuredMessage(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false
    ) async throws -> String {
        let stream = await chatStream(
            messages: [LLMMessage(role: .user, content: content)],
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
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false,
        useFastModel: Bool = false
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let provider = await configuration.provider
        let prepared = StructuredOutputExecution.prepareRequest(
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

    struct PreparedRequest {
        let messages: [LLMMessage]
        let tools: [LLMToolDefinition]?
        let toolChoice: LLMToolChoice?
        let responseFormat: LLMResponseFormat?
        let syntheticToolName: String?
        let promptAugmentation: String?
    }

    static func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        provider: LLMProvider,
        output: StructuredOutputRequest
    ) -> PreparedRequest {
        switch output {
        case .jsonObject:
            return PreparedRequest(
                messages: messages,
                tools: tools,
                toolChoice: nil,
                responseFormat: .jsonObject,
                syntheticToolName: nil,
                promptAugmentation: nil
            )
        case .jsonSchema(let schema):
            switch provider {
            case .openAI, .openRouter:
                return PreparedRequest(
                    messages: messages,
                    tools: tools,
                    toolChoice: nil,
                    responseFormat: .jsonSchema(.init(
                        name: schema.name,
                        description: schema.description,
                        schema: schema.schema,
                        strict: schema.strict
                    )),
                    syntheticToolName: nil,
                    promptAugmentation: nil
                )
            case .ollama:
                let augmentation = fallbackPromptSuffix(schema: schema)
                return PreparedRequest(
                    messages: applyPromptAugmentation(augmentation, to: messages),
                    tools: tools,
                    toolChoice: nil,
                    responseFormat: .jsonSchema(.init(
                        name: schema.name,
                        description: schema.description,
                        schema: schema.schema,
                        strict: schema.strict
                    )),
                    syntheticToolName: nil,
                    promptAugmentation: augmentation
                )
            case .openAICompatible:
                let syntheticTool = syntheticTool(for: schema)
                return PreparedRequest(
                    messages: messages,
                    tools: (tools ?? []) + [syntheticTool],
                    toolChoice: .function(syntheticToolName),
                    responseFormat: nil,
                    syntheticToolName: syntheticToolName,
                    promptAugmentation: nil
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
        to messages: [LLMMessage]
    ) -> [LLMMessage] {
        var updatedMessages = messages

        for index in updatedMessages.indices.reversed() {
            guard updatedMessages[index].role == .user else { continue }
            updatedMessages[index] = LLMMessage(
                role: .user,
                content: updatedMessages[index].content + augmentation,
                name: updatedMessages[index].name,
                toolCallID: updatedMessages[index].toolCallID,
                toolCalls: updatedMessages[index].toolCalls
            )
            return updatedMessages
        }

        updatedMessages.append(LLMMessage(
            role: .user,
            content: augmentation.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        return updatedMessages
    }

    private static func syntheticTool(for schema: StructuredOutputSchema) -> LLMToolDefinition {
        return LLMToolDefinition(
            name: syntheticToolName,
            description: schema.description ?? "Emit the final structured response payload for \(schema.name).",
            parameters: schema.schema,
            strict: schema.strict
        )
    }

    static func rewriteSyntheticToolStream(
        _ stream: AsyncThrowingStream<LLMStreamChunk, Error>,
        syntheticToolName: String
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
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
        _ result: LLMStreamChunk,
        syntheticToolName: String
    ) -> LLMStreamChunk? {
        guard let choice = result.choices.first else { return result }
        let toolCalls = choice.delta.toolCalls ?? []
        let syntheticCalls = toolCalls.filter { $0.function?.name == syntheticToolName }

        guard !syntheticCalls.isEmpty else { return result }

        let contentParts = syntheticCalls.compactMap { $0.function?.arguments }.filter { !$0.isEmpty }
        let mergedContent = contentParts.joined()

        guard !mergedContent.isEmpty else { return nil }

        return LLMStreamChunk(
            id: result.id,
            model: result.model,
            choices: [LLMStreamChoice(
                index: choice.index,
                delta: LLMStreamDelta(role: .assistant, content: mergedContent),
                finishReason: choice.finishReason
            )],
            usage: result.usage
        )
    }
}
