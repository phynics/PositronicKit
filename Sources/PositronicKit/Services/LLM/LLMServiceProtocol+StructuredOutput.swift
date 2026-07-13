import Foundation
import PKShared
import PKUtilities

public extension LLMStreamClient {
    func sendStructuredMessage(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary
    ) async throws -> String {
        let stream = await chatStream(
            messages: [LLMMessage(role: .user, content: content)],
            tools: nil,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier
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
        modelTier: ModelTier = .primary
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
            modelTier: modelTier
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
        modelTier: ModelTier = .primary
    ) async throws -> T {
        let response = try await sendStructuredMessage(
            content,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier
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
                        for rewritten in rewriteSyntheticToolChunk(result, syntheticToolName: syntheticToolName) {
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

    /// Rewrites a single streaming chunk for the synthetic-tool fallback.
    ///
    /// When a chunk carries only synthetic `emit_structured_response` calls, they are merged
    /// into a single content chunk (existing behavior). When a chunk carries only non-synthetic
    /// tool calls, it passes through unchanged. When a chunk carries *both*, the synthetic
    /// arguments are emitted as a content chunk first, followed by a separate chunk carrying
    /// the non-synthetic tool-call deltas — the original implementation discarded the latter.
    /// `finishReason` and `usage` defer to the trailing non-synthetic chunk so completion and
    /// token totals are reported exactly once on the final chunk of the pair.
    private static func rewriteSyntheticToolChunk(
        _ result: LLMStreamChunk,
        syntheticToolName: String
    ) -> [LLMStreamChunk] {
        guard let choice = result.choices.first else { return [result] }
        let toolCalls = choice.delta.toolCalls ?? []
        let syntheticCalls = toolCalls.filter { $0.function?.name == syntheticToolName }

        guard !syntheticCalls.isEmpty else { return [result] }

        let contentParts = syntheticCalls.compactMap { $0.function?.arguments }.filter { !$0.isEmpty }
        let mergedContent = contentParts.joined()
        let nonSyntheticCalls = toolCalls.filter { $0.function?.name != syntheticToolName }

        let hasSyntheticContent = !mergedContent.isEmpty
        let hasNonSynthetic = !nonSyntheticCalls.isEmpty

        guard hasSyntheticContent || hasNonSynthetic else { return [] }

        var chunks: [LLMStreamChunk] = []

        if hasSyntheticContent {
            let finishReason = hasNonSynthetic ? nil : choice.finishReason
            let usage = hasNonSynthetic ? nil : result.usage
            chunks.append(LLMStreamChunk(
                id: result.id,
                model: result.model,
                choices: [LLMStreamChoice(
                    index: choice.index,
                    delta: LLMStreamDelta(role: .assistant, content: mergedContent),
                    finishReason: finishReason
                )],
                usage: usage
            ))
        }

        if hasNonSynthetic {
            chunks.append(LLMStreamChunk(
                id: result.id,
                model: result.model,
                choices: [LLMStreamChoice(
                    index: choice.index,
                    delta: LLMStreamDelta(role: .assistant, toolCalls: nonSyntheticCalls),
                    finishReason: choice.finishReason
                )],
                usage: result.usage
            ))
        }

        return chunks
    }
}
