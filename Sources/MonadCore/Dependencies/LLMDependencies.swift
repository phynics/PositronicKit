import Dependencies
import Foundation
import MonadShared
import OpenAI

// MARK: - Dependency Keys

public enum LLMServiceKey: DependencyKey {
    public static let liveValue: any LLMServiceProtocol = UnconfiguredLLMService()
    public static let testValue: any LLMServiceProtocol = UnconfiguredLLMService()
}

public enum EmbeddingServiceKey: DependencyKey {
    public static let liveValue: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    public static let testValue: any EmbeddingServiceProtocol = NoOpEmbeddingService()
}

// MARK: - Dependency Values

public extension DependencyValues {
    var llmService: any LLMServiceProtocol {
        get { self[LLMServiceKey.self] }
        set { self[LLMServiceKey.self] = newValue }
    }

    var embeddingService: any EmbeddingServiceProtocol {
        get { self[EmbeddingServiceKey.self] }
        set { self[EmbeddingServiceKey.self] = newValue }
    }
}

// MARK: - Placeholder Implementations

public struct UnconfiguredLLMService: LLMServiceProtocol {
    public init() {}
    private func fail() -> Never {
        fatalError("LLMService not configured. Call 'MonadCore.configure()'.")
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

    public func getHealthStatus() async -> HealthStatus {
        .down
    }

    public func getHealthDetails() async -> [String: String]? {
        ["error": "Unconfigured"]
    }

    public func checkHealth() async -> HealthStatus {
        .down
    }

    public func loadConfiguration() async {}
    public func updateConfiguration(_: LLMConfiguration) async throws {
        fail()
    }

    public func clearConfiguration() async {}
    public func restoreFromBackup() async throws {
        fail()
    }

    public func exportConfiguration() async throws -> Data {
        fail()
    }

    public func importConfiguration(from _: Data) async throws {
        fail()
    }

    public func sendMessage(_: String) async throws -> String {
        fail()
    }

    public func sendMessage(
        _: String,
        responseFormat _: ChatQuery.ResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String {
        fail()
    }

    public func chatStreamWithContext(_: LLMChatRequest) async throws -> LLMStreamResult {
        return LLMStreamResult(stream: AsyncThrowingStream { _ in }, rawPrompt: "")
    }

    public func chatStream(
        messages _: [ChatQuery.ChatCompletionMessageParam],
        tools _: [ChatQuery.ChatCompletionToolParam]?,
        responseFormat _: ChatQuery.ResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool,
        useFastModel _: Bool
    ) async -> AsyncThrowingStream<ChatStreamResult, any Error> {
        return AsyncThrowingStream { _ in }
    }

    public func getClient() async -> (any LLMClientProtocol)? {
        nil
    }

    public func getUtilityClient() async -> (any LLMClientProtocol)? {
        nil
    }

    public func generateTags(for _: String) async throws -> [String] {
        fail()
    }

    public func generateTitle(for _: [Message]) async throws -> String {
        fail()
    }

    public func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] {
        fail()
    }

    public func fetchAvailableModels() async throws -> [String]? {
        nil
    }
}
