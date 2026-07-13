import Foundation
@testable import PKShared
import Testing

final class LLMConfigurationModelsTests {
    // MARK: - Test Helpers

    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test
    func lLMConfigurationCodable() throws {
        let config = LLMConfiguration(
            activeProvider: .openRouter,
            providers: [
                .openRouter: ProviderConfiguration(
                    endpoint: "https://openrouter.ai/api/v1",
                    apiKey: "sk-or-v1-test",
                    modelName: "anthropic/claude-3-5-sonnet",
                    utilityModel: "gpt-4o-mini",
                    fastModel: "gpt-4o-mini",
                    toolFormat: .openAI
                ),
            ]
        )
        try assertCodable(config)
    }

    @Test
    func lLMConfigurationDefault() {
        let config = LLMConfiguration.default
        #expect(config.activeProvider == .openAI)
    }

    // MARK: - LLMProvider

    @Test
    func lLMProviderCodableAndStr() throws {
        let p1 = LLMProvider.openAI
        try assertCodable(p1)
        #expect(p1.rawValue == "OpenAI")

        let p2 = LLMProvider.openRouter
        #expect(p2.rawValue == "OpenRouter")

        let p3 = LLMProvider.ollama
        #expect(p3.rawValue == "Ollama")
    }

    // MARK: - ProviderConfiguration

    @Test
    func providerConfigurationCodable() throws {
        let config = ProviderConfiguration(
            endpoint: "http://localhost:11434/api",
            apiKey: "",
            modelName: "llama3",
            utilityModel: "llama3",
            fastModel: "llama3",
            toolFormat: .openAI
        )
        try assertCodable(config)
        #expect(config.toolFormat == .openAI)
    }

    @Test
    func lLMParametersCodable() throws {
        var config = ProviderConfiguration(
            endpoint: "http://localhost:11434/api",
            apiKey: "",
            modelName: "llama3",
            utilityModel: "llama3",
            fastModel: "llama3",
            toolFormat: .openAI
        )

        config.temperature = 0.7
        config.maxTokens = 1000
        config.topP = 0.9
        config.frequencyPenalty = 0.5
        config.presencePenalty = 0.3
        config.seed = 42

        try assertCodable(config)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(ProviderConfiguration.self, from: data)

        #expect(decoded.temperature == 0.7)
        #expect(decoded.maxTokens == 1000)
        #expect(decoded.topP == 0.9)
        #expect(decoded.frequencyPenalty == 0.5)
        #expect(decoded.presencePenalty == 0.3)
        #expect(decoded.seed == 42)
    }

    @Test
    func lLMConfigurationActiveProviderConfiguration() {
        var config = LLMConfiguration.default

        config.providers[config.activeProvider]?.temperature = 0.8
        config.providers[config.activeProvider]?.maxTokens = 2000
        config.providers[config.activeProvider]?.topP = 0.95
        config.providers[config.activeProvider]?.frequencyPenalty = 0.1
        config.providers[config.activeProvider]?.presencePenalty = 0.2
        config.providers[config.activeProvider]?.seed = 42

        #expect(config.activeProviderConfiguration.temperature == 0.8)
        #expect(config.activeProviderConfiguration.maxTokens == 2000)
        #expect(config.activeProviderConfiguration.topP == 0.95)
        #expect(config.activeProviderConfiguration.frequencyPenalty == 0.1)
        #expect(config.activeProviderConfiguration.presencePenalty == 0.2)
        #expect(config.activeProviderConfiguration.seed == 42)

        // activeProviderConfiguration falls back to that provider's defaults when `providers`
        // has no entry for it.
        let sparse = LLMConfiguration(activeProvider: .anthropic, providers: [:])
        #expect(sparse.activeProviderConfiguration.modelName == ProviderConfiguration.defaultFor(.anthropic).modelName)
        #expect(sparse.activeProviderConfiguration.topP == nil)
    }

    // MARK: - ToolCallFormat

    @Test
    func toolCallFormatCodable() throws {
        // PKCLEAN-007: `.json`/`.xml` were removed; `.openAI` is the only case
        // and must round-trip cleanly.
        try assertCodable(ToolCallFormat.openAI)
    }

    @Test
    func toolCallFormatDecodesUnknownRawValueAsOpenAI() throws {
        // PKCLEAN-007: lenient decode for on-disk configs predating the
        // `.json`/`.xml` removal — stale raw values fall back to `.openAI`
        // instead of throwing.
        let decoder = JSONDecoder()
        for staleRawValue in ["JSON", "XML"] {
            let json = "\"\(staleRawValue)\"".data(using: .utf8)!
            let decoded = try decoder.decode(ToolCallFormat.self, from: json)
            #expect(decoded == .openAI)
        }
    }
}
