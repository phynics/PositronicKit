import Foundation
import ErrorKit
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
