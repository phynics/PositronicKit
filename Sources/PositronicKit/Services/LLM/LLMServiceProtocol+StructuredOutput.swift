import Foundation
import PKShared

public extension LLMStreamClient {
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

    static func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        provider: LLMProvider,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
        let adapter = StructuredOutputAdapterRegistry.adapter(for: provider)
            ?? DefaultStructuredOutputAdapter()
        return adapter.prepareRequest(messages: messages, tools: tools, output: output)
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
