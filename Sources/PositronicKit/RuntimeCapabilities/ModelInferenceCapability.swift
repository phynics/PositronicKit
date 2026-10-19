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
    private let languageModelClient: any LLMStreamClient
    private let streamTimeout: TimeInterval
    private let generationParameters: GenerationParameters?
    private let clock: any RuntimeClock
    private let promptCaching: PromptCachingPolicy

    init(
        languageModelClient: any LLMStreamClient,
        streamTimeout: TimeInterval,
        generationParameters: GenerationParameters?,
        clock: any RuntimeClock,
        promptCaching: PromptCachingPolicy = .automatic()
    ) {
        self.languageModelClient = languageModelClient
        self.streamTimeout = streamTimeout
        self.generationParameters = generationParameters
        self.clock = clock
        self.promptCaching = promptCaching
    }

    /// Returns the model's current non-network readiness snapshot.
    ///
    /// This does not read credentials, mutate configuration, or contact a provider. A
    /// subsequent operation remains authoritative because model state can change after the
    /// snapshot is read.
    public func readiness() async -> ModelReadiness {
        await languageModelClient.readiness
    }

    /// Performs the injected model's explicit health check.
    ///
    /// A conforming provider may perform network I/O during this operation. The result reports
    /// the provider's health check at that moment; it does not reserve or guarantee a later
    /// generation request. Throws ``ModelHealthError/unsupported`` when the injected client
    /// does not conform to ``HealthCheckable``.
    public func checkHealth() async throws -> HealthStatus {
        guard let healthCheckable = languageModelClient as? any HealthCheckable else {
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
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request because the provider
    ///     returns one terminal chunk.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    /// - Returns: The assembled content plus the provider's terminal metadata.
    public func generate(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) async throws -> LLMResponse {
        try await completeResult(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }

    /// Generates one complete response from host-rendered messages, without creating or
    /// updating a Timeline.
    ///
    /// The messages are sent exactly as supplied, in order. This is the one-shot convenience
    /// over the same provider contract as ``PKContracts/LLMClientProtocol``: the host owns conversation
    /// history, tool definitions, tool choice, and any follow-up requests. The runtime neither
    /// reads nor writes Timeline or Agent state, and it does not execute returned tool calls.
    /// Use ``stream(messages:tools:toolChoice:responseFormat:generationParameters:idleTimeout:transport:promptCaching:)``
    /// when the caller needs raw chunks or incremental tool-call deltas.
    ///
    /// - Parameters:
    ///   - messages: The ordered provider-neutral conversation to send.
    ///   - tools: Tool definitions to offer the model, if any.
    ///   - toolChoice: How the model should select among `tools`, if constrained.
    ///   - responseFormat: The response shape to request, if any.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request because the provider
    ///     returns one terminal chunk.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    /// - Returns: The assembled content, terminal metadata, and any complete tool calls.
    public func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) async throws -> LLMResponse {
        try await completeResult(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }

    /// Streams a response from host-rendered messages, without creating or updating a Timeline.
    ///
    /// The messages, tool definitions, tool choice, and response format reach the provider
    /// unchanged. Chunks carry the provider's incremental tool-call deltas; fold them with
    /// `LLMStreamChunk.folding(_:)` to assemble complete calls. The runtime does not execute
    /// them.
    ///
    /// - Parameters:
    ///   - messages: The ordered provider-neutral conversation to send.
    ///   - tools: Tool definitions to offer the model, if any.
    ///   - toolChoice: How the model should select among `tools`, if constrained.
    ///   - responseFormat: The response shape to request, if any.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    /// - Returns: The provider's raw chunk stream. Cancelling the consuming task cancels the
    ///   underlying provider request.
    public func stream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamChunks(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout ?? configuredStreamTimeout,
            transport: transport,
            promptCaching: promptCaching
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
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    ///   - decoder: The decoder used to turn the model's JSON payload into `Output`.
    /// - Returns: The decoded structured response.
    /// - Throws: `PKContracts.StructuredGenerationError.schemaConstructionFailed(typeName:reason:)` when
    ///   the generated schema cannot be constructed. Provider, timeout, cancellation, and
    ///   payload-decoding errors are thrown unchanged from their existing paths.
    public func generate<Output>(
        _ type: Output.Type,
        from prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil,
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
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )

        return try StructuredOutputDecoder.decode(Output.self, from: payload, decoder: decoder)
    }

    /// Streams a response for a single prompt, without creating or updating a Timeline.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    /// - Returns: The provider's raw chunk stream. Cancelling the consuming task cancels the
    ///   underlying provider request.
    public func stream(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamChunks(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout ?? configuredStreamTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }

    /// Generates the raw structured-output payload for a single prompt, without creating or
    /// updating a Timeline.
    ///
    /// This is the raw-payload companion to
    /// ``generate(_:from:generationParameters:idleTimeout:transport:promptCaching:decoder:)``: it returns the
    /// provider's JSON string instead of decoding it into a value. Use it when the caller needs
    /// the raw payload, a hand-built schema, or plain JSON-object mode.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - structuredOutput: The schema the response must conform to.
    ///   - generationParameters: Per-call generation parameters. Defaults to the facade's
    ///     configured parameters when `nil`.
    ///   - idleTimeout: Maximum idle time between streamed chunks, in seconds. Defaults to the
    ///     runtime's configured `RuntimeConfiguration.streamTimeout`; pass a value to override it
    ///     for this call. With `.requestResponse`, it bounds the whole request.
    ///   - transport: Which provider transport to use. Streaming is the default.
    ///   - promptCaching: Overrides the runtime's prompt-caching policy for this call. `nil`
    ///     uses the runtime default. This Timeline-free path has no Timeline routing key, so
    ///     the directive carries only the retention window.
    /// - Returns: The raw structured payload (JSON), decodable via `StructuredOutputDecoder`.
    public func generate(
        _ prompt: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) async throws -> String {
        try await complete(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }
}

// MARK: - Timeline-free generation

extension ModelInferenceCapability {
    /// Generates a response for a single prompt without creating or updating a timeline.
    func complete(_ prompt: String, transport: GenerationTransport = .streaming) async throws -> String {
        let response = try await completeResult(prompt, transport: transport)
        return response.content ?? ""
    }

    /// The idle timeout applied to the Timeline-free `kit.model` paths when a caller does not
    /// override it: the same `RuntimeConfiguration.streamTimeout` the Turn pipeline uses, so
    /// one-shot generation and full Turns share a single configured value.
    private var configuredStreamTimeout: TimeInterval {
        streamTimeout
    }

    /// Generates a response and returns provider terminal metadata without creating or updating a timeline.
    func completeResult(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) async throws -> LLMResponse {
        try await completeResult(
            messages: [LLMMessage(role: .user, content: prompt)],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }

    /// Generates a response from host-rendered messages without creating or updating a timeline.
    func completeResult(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval?,
        transport: GenerationTransport,
        promptCaching: PromptCachingPolicy?
    ) async throws -> LLMResponse {
        var chunks: [LLMStreamChunk] = []
        do {
            let stream = streamChunks(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                idleTimeout: idleTimeout ?? configuredStreamTimeout,
                transport: transport,
                promptCaching: promptCaching
            )
            for try await chunk in stream {
                chunks.append(chunk)
            }
            if Task.isCancelled { throw CancellationError() }
        } catch {
            throw wrapForeignError(error)
        }

        let provider = await languageModelClient.configuration.activeProvider
        let folded = try LLMStreamChunk.folding(chunks, provider: provider.rawValue)
        return Self.response(from: folded)
    }

    private static func response(from folded: LLMStreamChunk) -> LLMResponse {
        let firstChoice = folded.choices.first
        let content = folded.choices.compactMap { $0.delta.content }.joined()
        let toolCalls = firstChoice?.delta.toolCalls?.map { delta in
            LLMToolCall(
                id: delta.id ?? "",
                name: delta.function?.name ?? "",
                arguments: delta.function?.arguments ?? ""
            )
        }
        return LLMResponse(
            content: content,
            id: folded.id.isEmpty ? nil : folded.id,
            model: folded.model.isEmpty ? nil : folded.model,
            usage: folded.usage,
            finishReason: firstChoice?.finishReason,
            toolCalls: toolCalls?.isEmpty == false ? toolCalls : nil
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
        idleTimeout: TimeInterval? = nil,
        transport: GenerationTransport = .streaming,
        promptCaching: PromptCachingPolicy? = nil
    ) async throws -> String {
        try await languageModelClient.sendStructuredMessage(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters ?? self.generationParameters,
            idleTimeout: idleTimeout ?? configuredStreamTimeout,
            clock: clock,
            modelTier: .primary,
            transport: transport,
            promptCache: (promptCaching ?? self.promptCaching).keylessDirective
        )
    }

    /// Streams a response for a single prompt without creating or updating a timeline.
    private func streamChunks(
        _ prompt: String,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval,
        transport: GenerationTransport,
        promptCaching: PromptCachingPolicy? = nil
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamChunks(
            messages: [LLMMessage(role: .user, content: prompt)],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout,
            transport: transport,
            promptCaching: promptCaching
        )
    }

    /// Streams a response for host-rendered messages without creating or updating a timeline.
    private func streamChunks(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        idleTimeout: TimeInterval,
        transport: GenerationTransport,
        promptCaching: PromptCachingPolicy?
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let client = languageModelClient
        let defaultGenerationParameters = self.generationParameters
        let clock = self.clock
        let promptCache = (promptCaching ?? self.promptCaching).keylessDirective
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = await client.generation(
                        transport: transport,
                        messages: messages,
                        tools: tools,
                        toolChoice: toolChoice,
                        responseFormat: responseFormat,
                        generationParameters: generationParameters ?? defaultGenerationParameters,
                        modelTier: .primary,
                        responseModalities: [.text],
                        audioOutput: nil,
                        promptCache: promptCache
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
