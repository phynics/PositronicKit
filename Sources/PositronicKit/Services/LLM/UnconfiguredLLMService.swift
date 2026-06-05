import Foundation
import PKShared

public struct UnconfiguredLLMService: LLMServiceProtocol {
    public init() {}

    private func fail() -> Never {
        fatalError("LLMService not configured. Provide a configured LLM service.")
    }

    public var isConfigured: Bool {
        get async { false }
    }

    public var configuration: LLMConfiguration {
        get async {
            .init(
                activeProvider: .openAI,
                providers: [:],
                memoryContextLimit: 0,
                documentContextLimit: 0,
                version: 1
            )
        }
    }

    public func getHealthStatus() async -> HealthStatus { .down }
    public func getHealthDetails() async -> [String: String]? { ["error": "Unconfigured"] }
    public func checkHealth() async -> HealthStatus { .down }

    public func loadConfiguration() async {}
    public func updateConfiguration(_: LLMConfiguration) async throws { fail() }
    public func clearConfiguration() async {}
    public func restoreFromBackup() async throws { fail() }
    public func exportConfiguration() async throws -> Data { fail() }
    public func importConfiguration(from _: Data) async throws { fail() }

    public func sendMessage(_: String) async throws -> String { fail() }

    public func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { fail() }

    public func chatStreamWithContext(_: LLMChatRequest) async throws -> LLMStreamResult {
        LLMStreamResult(stream: AsyncThrowingStream { _ in }, rawPrompt: "")
    }

    public func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool,
        useFastModel _: Bool
    ) async -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { _ in }
    }

    public func getClient() async -> (any LLMClientProtocol)? { nil }
    public func getUtilityClient() async -> (any LLMClientProtocol)? { nil }
    public func fetchAvailableModels() async throws -> [String]? { nil }
}
