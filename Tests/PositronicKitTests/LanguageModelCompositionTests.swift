import Testing
import PKTestSupport
@testable import PositronicKit

@Suite("Language model composition")
struct LanguageModelCompositionTests {
    @Test("the facade reports a configured language model")
    func reportsConfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = true
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await kit.isLanguageModelConfigured)
    }

    @Test("the facade reports an unconfigured language model")
    func reportsUnconfiguredLanguageModel() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await !kit.isLanguageModelConfigured)
    }

    @Test("the facade reflects live language-model readiness changes")
    func reflectsLanguageModelReadinessChanges() async {
        let languageModel = MockLLMService()
        languageModel.mockIsConfigured = false
        let kit = PositronicKit(languageModel: languageModel)

        #expect(await !kit.isLanguageModelConfigured)

        languageModel.mockIsConfigured = true

        #expect(await kit.isLanguageModelConfigured)
    }

    @Test("the facade accepts an explicitly injected LanguageModel")
    func acceptsInjectedLanguageModel() async throws {
        let languageModel = MockLLMService()
        languageModel.mockClient.nextResponse = "injected"
        let kit = PositronicKit(languageModel: languageModel)

        let response = try await kit.complete("hello")

        #expect(response == "injected")
    }

    @Test("provider configuration exposes the injected LanguageModel")
    func providerConfigurationExposesLanguageModel() {
        let languageModel = MockLLMService()
        let configuration = PositronicKit.ProviderConfiguration(languageModel: languageModel)

        #expect(configuration.languageModel is MockLLMService)
    }
}
