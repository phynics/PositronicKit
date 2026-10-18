import Foundation
import PKContracts
import Testing
@testable import PositronicKit

@Suite("Prompt budget derivation (PKRR-001)", .tags(.unit))
struct PromptBudgetDerivationTests {
    @Test("A 512-token output limit does not shrink the prompt budget toward the output limit")
    func smallOutputLimitKeepsLargeBudget() throws {
        let budget = try TurnEngine.makePromptBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: 512
        )
        #expect(budget.contextWindowTokens == 128_000)
        #expect(budget.availableTokens == 128_000 - 512 - TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens > 126_000)
    }

    @Test("The prompt budget is derived from the context window, not the output limit")
    func budgetFromContextWindowNotOutputLimit() throws {
        let budget = try TurnEngine.makePromptBudget(
            contextWindowTokens: 200_000,
            maxOutputTokens: 512
        )
        #expect(budget.contextWindowTokens == 200_000)
        #expect(budget.reserveForResponse == 512 + TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 200_000 - 512 - TurnEngine.Constants.providerOverhead)
    }

    @Test("Nil output limit falls back to the default output reserve")
    func nilOutputLimitUsesDefaultReserve() throws {
        let budget = try TurnEngine.makePromptBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: nil
        )
        #expect(budget.reserveForResponse == TurnEngine.Constants.defaultOutputReserve + TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 128_000 - TurnEngine.Constants.defaultOutputReserve - TurnEngine.Constants.providerOverhead)
    }

    @Test("Context window override is independent of the output limit")
    func contextWindowOverrideIsIndependent() throws {
        let small = try TurnEngine.makePromptBudget(contextWindowTokens: 8_192, maxOutputTokens: 512)
        let large = try TurnEngine.makePromptBudget(contextWindowTokens: 200_000, maxOutputTokens: 512)
        #expect(small.availableTokens < 8_192)
        #expect(large.availableTokens == 200_000 - 512 - TurnEngine.Constants.providerOverhead)
        #expect(large.availableTokens > 198_000)
        #expect(small.contextWindowTokens == 8_192)
        #expect(large.contextWindowTokens == 200_000)
    }

    @Test("Rejects a context window smaller than the output reserve")
    func rejectsContextWindowSmallerThanReserve() {
        #expect(throws: PromptBudgetError.self) {
            try TurnEngine.makePromptBudget(contextWindowTokens: 100, maxOutputTokens: 4_096)
        }
    }

    @Test("Rejects non-positive context window")
    func rejectsNonPositiveContextWindow() {
        #expect(throws: PromptBudgetError.nonPositiveContextWindow(0)) {
            try TurnEngine.makePromptBudget(contextWindowTokens: 0, maxOutputTokens: 512)
        }
    }

    @Test("ProviderConfiguration defaultFor carries per-provider context windows")
    func providerDefaultsCarryContextWindows() {
        #expect(ProviderConfiguration.makeDefault(for: .openAI).contextWindowTokens == 128_000)
        #expect(ProviderConfiguration.makeDefault(for: .anthropic).contextWindowTokens == 200_000)
        #expect(ProviderConfiguration.makeDefault(for: .ollama).contextWindowTokens == 8_192)
        #expect(ProviderConfiguration.makeDefault(for: .openRouter).contextWindowTokens == 128_000)
        #expect(ProviderConfiguration.makeDefault(for: .openAICompatible).contextWindowTokens == 8_192)
    }

    @Test("Host can override contextWindowTokens on a provider configuration")
    func hostCanOverrideContextWindow() throws {
        var config = ProviderConfiguration.makeDefault(for: .openAI)
        config.contextWindowTokens = 32_000
        let budget = try TurnEngine.makePromptBudget(
            contextWindowTokens: config.contextWindowTokens,
            maxOutputTokens: 512
        )
        #expect(budget.contextWindowTokens == 32_000)
        #expect(budget.availableTokens == 32_000 - 512 - TurnEngine.Constants.providerOverhead)
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

    // MARK: - Assembled history budget

    @Test("The history budget subtracts the assembled fixed prompt from available input")
    func historyBudgetSubtractsAssembledFixedPrompt() {
        let budget = PromptHistoryOptimizer.historyBudget(
            availablePromptTokens: 128_000 - 4_608,
            fixedPromptTokens: 2_000
        )
        #expect(budget == 128_000 - 4_608 - 2_000)
    }

    @Test("The history budget never goes negative")
    func historyBudgetNeverNegative() {
        #expect(PromptHistoryOptimizer.historyBudget(availablePromptTokens: 1_000, fixedPromptTokens: 4_608) == 0)
    }

    @Test("A fixed prompt at the available-token boundary leaves no history capacity")
    func fixedPromptAtBoundaryLeavesNoHistoryBudget() {
        #expect(PromptHistoryOptimizer.historyBudget(availablePromptTokens: 1_000, fixedPromptTokens: 1_000) == 0)
    }

    @Test("Stepwise trimming keeps more history for a larger context-window budget")
    func stepwiseTrimScalesWithContextWindow() {
        let history = (0 ..< 200).map { index in
            Message(content: "message-\(index) " + String(repeating: "x", count: 400), role: .user)
        }

        func retained(_ contextWindow: Int) -> Int {
            PromptHistoryOptimizer.stepwise(
                history,
                availableTokens: PromptHistoryOptimizer.historyBudget(
                    availablePromptTokens: contextWindow,
                    fixedPromptTokens: 2_000
                ),
                state: HistoryTrimState()
            ).messages.count
        }

        #expect(retained(8_192) < retained(1_000_000))
    }
}
