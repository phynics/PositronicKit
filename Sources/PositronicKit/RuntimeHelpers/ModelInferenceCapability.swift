import Foundation
import ErrorKit
import JSONSchema
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Errors returned by model capability operations that are not available for an injected client.
public enum ModelHealthError: PKError, Sendable, Equatable {
    /// The injected client does not conform to ``HealthCheckable``.
    case unsupported

    public var errorDomain: String { PKErrorDomain.runtime }

    public var errorCode: Int { 1010 }

    public var userFriendlyMessage: String {
        "The injected model does not provide a health check."
    }
}

/// Raw, Timeline-free model inference entry points exposed by ``PKRuntime``.
public struct ModelInferenceCapability: Sendable {
    private let kit: PKRuntime

    init(kit: PKRuntime) {
        self.kit = kit
    }

    public var isConfigured: Bool {
        get async { await kit.isLanguageModelConfigured }
    }

    /// Returns the model's current non-network readiness snapshot.
    ///
    /// This does not read credentials, mutate configuration, or contact a provider. A
    /// subsequent operation remains authoritative because model state can change after the
    /// snapshot is read.
    public func readiness() async -> ModelReadiness {
        await kit.languageModelClient.readiness
    }

    /// Performs the injected model's explicit health check.
    ///
    /// A conforming provider may perform network I/O during this operation. The result reports
    /// the provider's health check at that moment; it does not reserve or guarantee a later
    /// generation request. Throws ``ModelHealthError/unsupported`` when the injected client
    /// does not conform to ``HealthCheckable``.
    public func checkHealth() async throws -> HealthStatus {
        guard let healthCheckable = kit.languageModelClient as? any HealthCheckable else {
            throw ModelHealthError.unsupported
        }
        return await healthCheckable.checkHealth()
    }

    /// Generates a complete response for a single prompt, without creating or updating a Timeline.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. This defaults to
    ///     60 seconds rather than the runtime's configured `RuntimeConfiguration.streamTimeout`:
    ///     a default argument is baked in at the call site, so honouring the configured value
    ///     here would change this method's public signature. Pass the value explicitly to match
    ///     a non-default runtime configuration.
    /// - Returns: The assembled content plus the provider's terminal metadata.
    public func generate(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) async throws -> LLMResponse {
        try await completeResult(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    /// Generates and decodes one structured response for a single prompt, without creating or
    /// updating a Timeline.
    ///
    /// The result type must provide a JSON Schema through `@Schemable`. The generated schema's
    /// keys must agree with the keys accepted by `decoder`, including any explicit `CodingKeys`
    /// or custom decoding strategy.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to request and return.
    ///   - prompt: The user prompt to send.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. This defaults to
    ///     60 seconds and is applied by the existing one-shot structured-output path.
    ///   - decoder: The decoder used to turn the model's JSON payload into `Output`.
    /// - Returns: The decoded structured response.
    /// - Throws: `PKContracts.StructuredGenerationError.schemaConstructionFailed(typeName:reason:)` when
    ///   the generated schema cannot be constructed. Provider, timeout, cancellation, and
    ///   payload-decoding errors are thrown unchanged from their existing paths.
    public func generate<Output>(
        _ type: Output.Type,
        from prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60,
        decoder: JSONDecoder = SerializationUtils.jsonDecoder
    ) async throws -> Output
    where
        Output: Decodable & Sendable & Schemable,
        Output.Schema.Output == Output
    {
        let schema: Schema
        do {
            schema = try Schema(
                rawSchema: Output.schema.schemaValue.value,
                context: Context(dialect: .draft2020_12)
            )
        } catch {
            throw StructuredGenerationError.schemaConstructionFailed(
                typeName: String(reflecting: Output.self),
                reason: String(describing: error)
            )
        }

        let request = StructuredOutputRequest.jsonSchema(StructuredOutputSchema(
            name: Output.defaultAnchor,
            schema: schema
        ))
        let payload = try await complete(
            prompt,
            structuredOutput: request,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )

        return try StructuredOutputDecoder.decode(Output.self, from: payload, decoder: decoder)
    }

    /// Streams a response for a single prompt, without creating or updating a Timeline.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. This defaults to
    ///     60 seconds rather than the runtime's configured `RuntimeConfiguration.streamTimeout`:
    ///     a default argument is baked in at the call site, so honouring the configured value
    ///     here would change this method's public signature. Pass the value explicitly to match
    ///     a non-default runtime configuration.
    /// - Returns: The provider's raw chunk stream. Cancelling the consuming task cancels the
    ///   underlying provider request.
    public func stream(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamChunks(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    /// Generates the raw structured-output payload for a single prompt, without creating or
    /// updating a Timeline.
    ///
    /// This is the raw-payload companion to
    /// ``generate(_:from:generationParameters:idleTimeout:decoder:)``: it returns the
    /// provider's JSON string instead of decoding it into a value. Use it when the caller needs
    /// the raw payload, a hand-built schema, or plain JSON-object mode.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - structuredOutput: The schema the response must conform to.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. This defaults to
    ///     60 seconds rather than the runtime's configured `RuntimeConfiguration.streamTimeout`:
    ///     a default argument is baked in at the call site, so honouring the configured value
    ///     here would change this method's public signature. Pass the value explicitly to match
    ///     a non-default runtime configuration.
    /// - Returns: The raw structured payload (JSON), decodable via `StructuredOutputDecoder`.
    public func generate(
        _ prompt: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) async throws -> String {
        try await complete(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }
}

// MARK: - Timeline-free generation

extension ModelInferenceCapability {
    /// Generates a response for a single prompt without creating or updating a timeline.
    func complete(_ prompt: String) async throws -> String {
        let response = try await completeResult(prompt)
        return response.content ?? ""
    }

    /// The idle timeout applied to the Timeline-free `kit.model` paths when a caller does not
    /// override it: the same `RuntimeConfiguration.streamTimeout` the Turn pipeline uses, so
    /// one-shot generation and full Turns share a single configured value.
    private var configuredStreamTimeout: TimeInterval {
        kit.turnEngine.dependencies.streamTimeout
    }

    /// Generates a response and returns provider terminal metadata without creating or updating a timeline.
    func completeResult(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil
    ) async throws -> LLMResponse {
        var chunks: [LLMStreamChunk] = []
        do {
            let stream = streamChunks(
                prompt,
                generationParameters: generationParameters,
                idleTimeout: idleTimeout ?? configuredStreamTimeout
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
            let provider = await kit.languageModelClient.configuration.activeProvider
            throw LLMServiceError.emptyResponse(provider: provider.rawValue)
        }

        let terminalChunk = chunks.last
        return LLMResponse(
            content: content,
            id: terminalChunk?.id,
            model: terminalChunk?.model,
            usage: chunks.reversed().compactMap(\.usage).first,
            finishReason: chunks.reversed().compactMap { $0.choices.first?.finishReason }.first
        )
    }

    /// Generates a structured response for a single prompt without creating or
    /// updating a timeline. The returned string is the raw structured payload
    /// (JSON), decodable via `StructuredOutputDecoder`.
    ///
    /// Structured output is routed through the same provider adapter path as the
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
        try await kit.languageModelClient.sendStructuredMessage(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters ?? kit.defaultGenerationParameters,
            idleTimeout: idleTimeout ?? configuredStreamTimeout,
            clock: kit.turnEngine.dependencies.clock,
            modelTier: .primary
        )
    }

    /// Streams a response for a single prompt without creating or updating a timeline.
    private func streamChunks(
        _ prompt: String,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let languageModelClient = kit.languageModelClient
        let defaultGenerationParameters = kit.defaultGenerationParameters
        let clock = kit.turnEngine.dependencies.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = await languageModelClient.generationStream(
                        messages: [LLMMessage(role: .user, content: prompt)],
                        tools: nil,
                        toolChoice: nil,
                        responseFormat: nil,
                        generationParameters: generationParameters ?? defaultGenerationParameters,
                        modelTier: .primary
                    )
                    try await StreamIdleTimeout.run(timeout: idleTimeout, clock: clock) { deadline in
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
