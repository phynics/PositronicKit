import Testing
import PKTestSupport
@testable import PositronicKit

@Suite("Language model composition")
struct LanguageModelCompositionTests {
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
