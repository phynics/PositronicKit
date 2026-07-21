import Foundation
import PKShared
import PKUtilities

public struct UnconfiguredLLMService: LanguageModel {
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
            // `LLMConfiguration`'s init (which always fills in `ProviderConfiguration.defaultFor(_:)`
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

    public func loadConfiguration() async {}
    public func updateConfiguration(_: LLMConfiguration) async throws {
        throw error
    }

    public func clearConfiguration() async {}
    public func restoreFromBackup() async throws {
        throw error
    }

    public func exportConfiguration() async throws -> Data {
        throw error
    }

    public func importConfiguration(from _: Data) async throws {
        throw error
    }

    public func sendMessage(_: String) async throws -> String {
        throw error
    }

    public func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String {
        throw error
    }

    public func chatStreamWithContext(_: LLMChatRequest) async throws -> LLMStreamResult {
        LLMStreamResult(stream: failingStream(), rawPrompt: "")
    }

    public func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        failingStream()
    }

    public func getClient() async -> (any LLMClientProtocol)? {
        nil
    }

    public func getUtilityClient() async -> (any LLMClientProtocol)? {
        nil
    }

    public func fetchAvailableModels() async throws -> [String]? {
        throw error
    }
}
