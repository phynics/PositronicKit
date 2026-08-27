import Foundation
import PKContracts
import PKUtilities

public struct UnconfiguredLLMService: LLMStreamClient, HealthCheckable {
    public init() {}

    private var error: LLMServiceError {
        .notConfigured
    }

    private func failingStream() -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    public var isConfigured: Bool {
        get async { false }
    }

    public var configuration: LLMConfiguration {
        get async {
            // Returns a minimal config with default provider entries populated by
            // `LLMConfiguration`'s init (which always fills in `ProviderConfiguration.makeDefault(for:)`
            // for every `LLMProvider`). The zero limits and `version: 1` signal that no real
            // provider is configured — `isConfigured` is `false` and all throwing methods
            // return `.notConfigured`.
            .init(
                activeProvider: .openAI,
                providers: [:],
                memoryContextLimit: 0,
                documentContextLimit: 0,
                version: 1
            )
        }
    }

    public func getHealthDetails() async -> [String: String]? {
        ["error": "Unconfigured"]
    }

    public func checkHealth() async -> HealthStatus {
        .down
    }

    public func generationStreamWithContext(_: LLMGenerationRequest) async throws -> LLMStreamResult {
        LLMStreamResult(stream: failingStream(), rawPrompt: "")
    }

    public func generationStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        failingStream()
    }

}
