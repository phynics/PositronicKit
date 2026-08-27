import Testing
import PKContracts
import PKTestSupport
import PositronicKit

private struct StreamOnlyClient: LLMStreamClient {
    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .openAI }
    }

    func generationStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("Language model composition")
struct LanguageModelCompositionTests {
    @Test("the facade reports a configured language model")
    func reportsConfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = true
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await kit.model.isConfigured)
    }

    @Test("the facade reports an unconfigured language model")
    func reportsUnconfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await !kit.model.isConfigured)
    }

    @Test("the facade reflects live language-model readiness changes")
    func reflectsLanguageModelReadinessChanges() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await !kit.model.isConfigured)

        languageModel.mockIsConfigured = true

        #expect(await kit.model.isConfigured)
    }

    @Test("the facade accepts an explicitly injected stream client")
    func acceptsInjectedStreamClient() async throws {
        let languageModel = MockLLMService()
        languageModel.mockClient.nextResponse = "injected"
        let kit = PositronicKit(languageModel: languageModel)

        let response = try await kit.model.generate("hello")

        #expect(response.content == "injected")
    }

    @Test("provider configuration exposes the injected stream client")
    func providerConfigurationExposesStreamClient() {
        let languageModel = MockLLMService()
        let configuration = PositronicKit.ProviderConfiguration(languageModel: languageModel)

        #expect(configuration.languageModel is MockLLMService)
    }

    @Test("the facade accepts a stream-only client")
    func acceptsStreamOnlyClient() async {
        let kit = PositronicKit(languageModel: StreamOnlyClient())

        #expect(await kit.model.isConfigured)
    }
}
