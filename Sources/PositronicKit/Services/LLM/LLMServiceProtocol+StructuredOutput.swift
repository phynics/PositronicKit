import Foundation
import PKContracts
import PKUtilities

public extension LLMStreamClient {
    func sendStructuredMessage(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        modelTier: ModelTier = .primary,
        transport: GenerationTransport = .streaming,
        promptCache: PromptCacheDirective? = nil
    ) async throws -> String {
        try await sendStructuredMessage(
            content,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            clock: ContinuousRuntimeClock(),
            modelTier: modelTier,
            transport: transport,
            promptCache: promptCache
        )
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary,
        transport: GenerationTransport = .streaming,
        promptCache: PromptCacheDirective? = nil
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await structuredGenerationStream(
            messages: messages,
            tools: tools,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: [.text],
            audioOutput: nil,
            transport: transport,
            promptCache: promptCache
        )
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        transport: GenerationTransport = .streaming,
        promptCache: PromptCacheDirective? = nil
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await structuredGenerationStream(
            messages: messages,
            tools: tools,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            transport: transport,
            promptCache: promptCache
        )
    }

    func sendStructured<T: Decodable & Sendable>(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        as type: T.Type = T.self,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary,
        transport: GenerationTransport = .streaming
    ) async throws -> T {
        let response = try await sendStructuredMessage(
            content,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier,
            transport: transport
        )

        return try StructuredOutputDecoder.decode(type, from: response, decoder: decoder)
    }
}

/// The single structured-preparation step shared by every structured streaming entry point
/// (Turn stage, one-shot `kit.model`, and ``LLMStreamClient/generationStreamWithContext(_:)``):
/// prepare the request for the selected tier's adapter, stream through the transport seam, and
/// rewrite a synthetic forced-tool call back into content deltas.
extension LLMStreamClient {
    func structuredGenerationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        transport: GenerationTransport,
        promptCache: PromptCacheDirective?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let prepared = StructuredOutputExecution.prepareRequest(
            messages: messages,
            tools: tools,
            adapter: await structuredOutputAdapter(for: modelTier),
            output: structuredOutput
        )
        return await generationStream(
            prepared: prepared,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            transport: transport,
            promptCache: promptCache
        )
    }

    func generationStream(
        prepared: PreparedStructuredOutputRequest,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?,
        transport: GenerationTransport,
        promptCache: PromptCacheDirective?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let stream = await generation(
            transport: transport,
            messages: prepared.messages,
            tools: prepared.tools,
            toolChoice: prepared.toolChoice,
            responseFormat: prepared.responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            promptCache: promptCache
        )
        guard let syntheticToolName = prepared.syntheticToolName else {
            return stream
        }
        return StructuredOutputExecution.rewriteSyntheticToolStream(stream, syntheticToolName: syntheticToolName)
    }
}

package extension LLMStreamClient {
    /// Structured send with the runtime clock injected, so callers inside the package can run
    /// the idle watchdog on virtual time. `RuntimeClock` is package-scoped, which is why this
    /// cannot simply be a defaulted parameter on the public entry point above.
    func sendStructuredMessage(
        _ content: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        clock: any RuntimeClock,
        modelTier: ModelTier = .primary,
        transport: GenerationTransport = .streaming,
        promptCache: PromptCacheDirective? = nil
    ) async throws -> String {
        let stream = await generationStream(
            messages: [LLMMessage(role: .user, content: content)],
            tools: nil,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            modelTier: modelTier,
            transport: transport,
            promptCache: promptCache
        )

        let provider = await configuration.activeProvider
        let timeout = idleTimeout ?? RuntimePolicy.defaultStreamTimeout
        let folded: LLMStreamChunk
        do {
            folded = try await StreamIdleTimeout.run(timeout: timeout, clock: clock) { deadline in
                var chunks: [LLMStreamChunk] = []
                for try await chunk in stream {
                    if Task.isCancelled { throw CancellationError() }
                    await deadline.reset()
                    chunks.append(chunk)
                }
                if Task.isCancelled { throw CancellationError() }
                return try LLMStreamChunk.folding(chunks, provider: provider.rawValue)
            }
        } catch {
            throw wrapForeignError(error)
        }
        return folded.choices.compactMap { $0.delta.content }.joined()
    }
}

enum StructuredOutputExecution {
    private static let syntheticToolName = "emit_structured_response"

    static func prepareRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        adapter: any StructuredOutputAdapter,
        output: StructuredOutputRequest
    ) -> PreparedStructuredOutputRequest {
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
