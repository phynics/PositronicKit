import Foundation
import PKContracts
import PKUtilities

/// The terminal result of a one-shot generation, without thread state.
public struct OneShotResult: Sendable, Equatable {
    public let content: String
    public let id: String?
    public let model: String?
    public let usage: LLMTokenUsage?
    public let finishReason: String?

    public init(
        content: String,
        id: String? = nil,
        model: String? = nil,
        usage: LLMTokenUsage? = nil,
        finishReason: String? = nil
    ) {
        self.content = content
        self.id = id
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
    }
}

extension PositronicKit {
    /// Generates a response for a single prompt without creating or updating a thread.
    func complete(_ prompt: String) async throws -> String {
        try await completeResult(prompt).content
    }

    /// The idle timeout applied to the Thread-free `kit.model` paths when a caller does not
    /// override it: the same `RuntimeConfiguration.streamTimeout` the Turn pipeline uses, so
    /// one-shot generation and full Turns share a single configured value.
    var configuredStreamTimeout: TimeInterval {
        turnEngine.dependencies.streamTimeout
    }

    /// Generates a response with per-call generation parameters.
    func complete(
        _ prompt: String,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval? = nil
    ) async throws -> String {
        try await completeResult(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        ).content
    }

    /// Generates a response and returns provider terminal metadata without creating or updating a thread.
    func completeResult(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil
    ) async throws -> OneShotResult {
        var chunks: [LLMStreamChunk] = []
        do {
            let stream = stream(
                prompt,
                generationParameters: generationParameters,
                idleTimeout: idleTimeout
            )
            for try await chunk in stream {
                chunks.append(chunk)
            }
            if Task.isCancelled { throw CancellationError() }
        } catch {
            throw wrapForeignError(error)
        }

        let content = chunks
            .flatMap { $0.choices.compactMap { $0.delta.content } }
            .joined()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let provider = await languageModel.configuration.activeProvider
            throw LLMServiceError.emptyResponse(provider: provider.rawValue)
        }

        let terminalChunk = chunks.last
        return OneShotResult(
            content: content,
            id: terminalChunk?.id,
            model: terminalChunk?.model,
            usage: chunks.reversed().compactMap(\.usage).first,
            finishReason: chunks.reversed().compactMap { $0.choices.first?.finishReason }.first
        )
    }

    /// Generates a structured response for a single prompt without creating or
    /// updating a thread. The returned string is the raw structured payload
    /// (JSON), decodable via `StructuredOutputDecoder`.
    ///
    /// Structured output is threaded through the same provider adapter path as the
    /// full chat pipeline (`StructuredOutputExecution`): the request is translated into
    /// either a native `responseFormat` or a synthetic forced tool call, and -- for the
    /// synthetic-tool path -- the underlying stream's tool-call argument deltas are
    /// rewritten into content deltas before being assembled here, so callers always see
    /// a plain JSON string regardless of how the provider actually returned it.
    func complete(
        _ prompt: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil
    ) async throws -> String {
        try await languageModel.sendStructuredMessage(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters ?? defaultGenerationParameters,
            idleTimeout: idleTimeout ?? configuredStreamTimeout,
            clock: turnEngine.dependencies.clock,
            modelTier: .primary
        )
    }

    /// Streams a response for a single prompt without creating or updating a thread.
    func stream(_ prompt: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        stream(prompt, generationParameters: nil, idleTimeout: nil)
    }

    /// Streams a response with per-call generation parameters and an inactivity timeout.
    func stream(
        _ prompt: String,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval? = nil
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let resolvedTimeout = idleTimeout ?? configuredStreamTimeout
        let clock = turnEngine.dependencies.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = await languageModel.generationStream(
                        messages: [LLMMessage(role: .user, content: prompt)],
                        tools: nil,
                        toolChoice: nil,
                        responseFormat: nil,
                        generationParameters: generationParameters ?? defaultGenerationParameters,
                        modelTier: .primary
                    )
                    try await StreamIdleTimeout.run(timeout: resolvedTimeout, clock: clock) { deadline in
                        for try await chunk in stream {
                            if Task.isCancelled { throw CancellationError() }
                            await deadline.reset()
                            continuation.yield(chunk)
                        }
                        if Task.isCancelled { throw CancellationError() }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: wrapForeignError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
