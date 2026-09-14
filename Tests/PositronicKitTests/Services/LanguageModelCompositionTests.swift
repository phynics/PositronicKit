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
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("Language model composition", .tags(.integration))
struct LanguageModelCompositionTests {
    @Test("the facade reports a configured language model")
    func reportsConfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = true
        let kit = PKRuntime(languageModel: languageModel)

        #expect(await kit.model.isConfigured)
    }

    @Test("the facade reports an unconfigured language model")
    func reportsUnconfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PKRuntime(languageModel: languageModel)

        #expect(await !kit.model.isConfigured)
    }

    @Test("the facade reflects live language-model readiness changes")
    func reflectsLanguageModelReadinessChanges() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PKRuntime(languageModel: languageModel)

        #expect(await !kit.model.isConfigured)

        languageModel.mockIsConfigured = true

        #expect(await kit.model.isConfigured)
    }

    @Test("the model capability distinguishes invalid configuration")
    func reportsInvalidConfigurationReadiness() async {
        let kit = PKRuntime()

        #expect(await kit.model.readiness() == .unavailable(.invalidConfiguration))
    }

    @Test("the model capability distinguishes a missing primary client")
    func reportsMissingClientReadiness() async {
        let configuration = LLMConfiguration.fixture(apiKey: "test-key")
        let service = LLMService(configuration: configuration, clients: .empty)
        let kit = PKRuntime(languageModel: service)

        #expect(await kit.model.readiness() == .unavailable(.clientUnavailable))
    }

    @Test("the model capability reports local readiness when a client is resolved")
    func reportsReadyModel() async {
        let languageModel = MockLLMService()
        let kit = PKRuntime(languageModel: languageModel)

        #expect(await kit.model.readiness() == .ready)
    }

    @Test("health delegates to a supported model client")
    func reportsSupportedHealth() async throws {
        let languageModel = MockLLMService()
        languageModel.mockHealthStatus = .ok
        let kit = PKRuntime(languageModel: languageModel)

        #expect(try await kit.model.checkHealth() == .ok)
    }

    @Test("health reports unsupported for a stream-only custom client")
    func reportsUnsupportedHealth() async {
        let kit = PKRuntime(languageModel: StreamOnlyClient())

        let error = await #expect(throws: ModelHealthError.self) {
            _ = try await kit.model.checkHealth()
        }

        #expect(error == .unsupported)
    }

    @Test("the facade accepts an explicitly injected stream client")
    func acceptsInjectedStreamClient() async throws {
        let languageModel = MockLLMService()
        languageModel.mockClient.nextResponse = "injected"
        let kit = PKRuntime(languageModel: languageModel)

        let response = try await kit.model.generate("hello")

        #expect(response.content == "injected")
    }

    @Test("grouped configuration exposes the injected stream client")
    func groupedConfigurationExposesStreamClient() {
        let languageModel = MockLLMService()
        let configuration = PKRuntime.Configuration(
            languageModel: languageModel,
            persistence: .inMemory()
        )

        #expect(configuration.languageModel is MockLLMService)
    }

    @Test("the facade accepts a stream-only client")
    func acceptsStreamOnlyClient() async {
        let kit = PKRuntime(languageModel: StreamOnlyClient())

        #expect(await kit.model.isConfigured)
    }
}
