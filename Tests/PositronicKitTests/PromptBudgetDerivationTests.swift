import Foundation
import PKPrompt
import PKShared
import Testing
@testable import PositronicKit

@Suite("Prompt budget derivation (PKRR-001)")
struct PromptBudgetDerivationTests {
    @Test("A 512-token output limit does not shrink the prompt budget toward the output limit")
    func smallOutputLimitKeepsLargeBudget() throws {
        let budget = try ChatEngine.makeTokenBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 128_000)
        #expect(budget.availableTokens == 128_000 - 512 - ChatEngine.Constants.providerOverhead)
        #expect(budget.availableTokens > 126_000)
    }

    @Test("The prompt budget is derived from the context window, not the output limit")
    func budgetFromContextWindowNotOutputLimit() throws {
        let budget = try ChatEngine.makeTokenBudget(
            contextWindowTokens: 200_000,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 200_000)
        #expect(budget.reserveForResponse == 512 + ChatEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 200_000 - 512 - ChatEngine.Constants.providerOverhead)
    }

    @Test("Nil output limit falls back to the default output reserve")
    func nilOutputLimitUsesDefaultReserve() throws {
        let budget = try ChatEngine.makeTokenBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: nil
        )
        #expect(budget.reserveForResponse == ChatEngine.Constants.defaultOutputReserve + ChatEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 128_000 - ChatEngine.Constants.defaultOutputReserve - ChatEngine.Constants.providerOverhead)
    }

    @Test("Context window override is independent of the output limit")
    func contextWindowOverrideIsIndependent() throws {
        let small = try ChatEngine.makeTokenBudget(contextWindowTokens: 8_192, maxOutputTokens: 512)
        let large = try ChatEngine.makeTokenBudget(contextWindowTokens: 200_000, maxOutputTokens: 512)
        #expect(small.availableTokens < 8_192)
        #expect(large.availableTokens == 200_000 - 512 - ChatEngine.Constants.providerOverhead)
        #expect(large.availableTokens > 198_000)
        #expect(small.maxTokens == 8_192)
        #expect(large.maxTokens == 200_000)
    }

    @Test("Rejects a context window smaller than the output reserve")
    func rejectsContextWindowSmallerThanReserve() {
        #expect(throws: TokenBudgetError.self) {
            try ChatEngine.makeTokenBudget(contextWindowTokens: 100, maxOutputTokens: 4_096)
        }
    }

    @Test("Rejects non-positive context window")
    func rejectsNonPositiveContextWindow() {
        #expect(throws: TokenBudgetError.nonPositiveContextWindow(0)) {
            try ChatEngine.makeTokenBudget(contextWindowTokens: 0, maxOutputTokens: 512)
        }
    }

    @Test("ProviderConfiguration defaultFor carries per-provider context windows")
    func providerDefaultsCarryContextWindows() {
        #expect(ProviderConfiguration.defaultFor(.openAI).contextWindowTokens == 128_000)
        #expect(ProviderConfiguration.defaultFor(.anthropic).contextWindowTokens == 200_000)
        #expect(ProviderConfiguration.defaultFor(.ollama).contextWindowTokens == 8_192)
        #expect(ProviderConfiguration.defaultFor(.openRouter).contextWindowTokens == 128_000)
        #expect(ProviderConfiguration.defaultFor(.openAICompatible).contextWindowTokens == 8_192)
    }

    @Test("Host can override contextWindowTokens on a provider configuration")
    func hostCanOverrideContextWindow() throws {
        var config = ProviderConfiguration.defaultFor(.openAI)
        config.contextWindowTokens = 32_000
        let budget = try ChatEngine.makeTokenBudget(
            contextWindowTokens: config.contextWindowTokens,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 32_000)
        #expect(budget.availableTokens == 32_000 - 512 - ChatEngine.Constants.providerOverhead)
        #expect(budget.availableTokens > 30_000)
    }

    @Test("ProviderConfiguration contextWindowTokens survives Codable round-trip")
    func contextWindowTokensCodable() throws {
        let config = ProviderConfiguration(
            endpoint: "https://api.openai.com",
            apiKey: "k",
            modelName: "gpt-4o",
            utilityModel: "gpt-4o-mini",
            fastModel: "gpt-4o-mini",
            toolFormat: .openAI,
            contextWindowTokens: 64_000
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)
        #expect(decoded.contextWindowTokens == 64_000)
    }

    @Test("ProviderConfiguration contextWindowTokens defaults when absent in JSON")
    func contextWindowTokensDefaultsWhenAbsent() throws {
        let json = """
        {"endpoint":"https://api.openai.com","apiKey":"k","modelName":"gpt-4o","utilityModel":"gpt-4o-mini","fastModel":"gpt-4o-mini","toolFormat":"openai"}
        """
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(json.utf8))
        #expect(decoded.contextWindowTokens == 8_192)
    }
}
