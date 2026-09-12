import Foundation
import ErrorKit
import JSONSchema
import JSONSchemaBuilder
import PKContracts

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

/// Raw, Thread-free model inference entry points exposed by ``PositronicKit``.
public struct ModelInferenceCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
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
        await kit.languageModel.readiness
    }

    /// Performs the injected model's explicit health check.
    ///
    /// A conforming provider may perform network I/O during this operation. The result reports
    /// the provider's health check at that moment; it does not reserve or guarantee a later
    /// generation request. Throws ``ModelHealthError/unsupported`` when the injected client
    /// does not conform to ``HealthCheckable``.
    public func checkHealth() async throws -> HealthStatus {
        guard let healthCheckable = kit.languageModel as? any HealthCheckable else {
            throw ModelHealthError.unsupported
        }
        return await healthCheckable.checkHealth()
    }

    /// Generates a complete response for a single prompt, without creating or updating a Thread.
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
    ) async throws -> OneShotResult {
        try await kit.completeResult(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    /// Generates and decodes one structured response for a single prompt, without creating or
    /// updating a Thread.
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
        let payload = try await kit.complete(
            prompt,
            structuredOutput: request,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )

        return try StructuredOutputDecoder.decode(Output.self, from: payload, decoder: decoder)
    }

    /// Streams a response for a single prompt, without creating or updating a Thread.
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
        kit.stream(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    /// Generates a structured response for a single prompt, without creating or updating a
    /// Thread.
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
    public func generateStructured(
        _ prompt: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) async throws -> String {
        try await kit.complete(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }
}
