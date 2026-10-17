import Foundation
import PKPrompt
import PKContracts
import Testing
@testable import PositronicKit

@Suite("Prompt budget derivation (PKRR-001)", .tags(.unit))
struct PromptBudgetDerivationTests {
    @Test("A 512-token output limit does not shrink the prompt budget toward the output limit")
    func smallOutputLimitKeepsLargeBudget() throws {
        let budget = try TurnEngine.makeTokenBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 128_000)
        #expect(budget.availableTokens == 128_000 - 512 - TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens > 126_000)
    }

    @Test("The prompt budget is derived from the context window, not the output limit")
    func budgetFromContextWindowNotOutputLimit() throws {
        let budget = try TurnEngine.makeTokenBudget(
            contextWindowTokens: 200_000,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 200_000)
        #expect(budget.reserveForResponse == 512 + TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 200_000 - 512 - TurnEngine.Constants.providerOverhead)
    }

    @Test("Nil output limit falls back to the default output reserve")
    func nilOutputLimitUsesDefaultReserve() throws {
        let budget = try TurnEngine.makeTokenBudget(
            contextWindowTokens: 128_000,
            maxOutputTokens: nil
        )
        #expect(budget.reserveForResponse == TurnEngine.Constants.defaultOutputReserve + TurnEngine.Constants.providerOverhead)
        #expect(budget.availableTokens == 128_000 - TurnEngine.Constants.defaultOutputReserve - TurnEngine.Constants.providerOverhead)
    }

    @Test("Context window override is independent of the output limit")
    func contextWindowOverrideIsIndependent() throws {
        let small = try TurnEngine.makeTokenBudget(contextWindowTokens: 8_192, maxOutputTokens: 512)
        let large = try TurnEngine.makeTokenBudget(contextWindowTokens: 200_000, maxOutputTokens: 512)
        #expect(small.availableTokens < 8_192)
        #expect(large.availableTokens == 200_000 - 512 - TurnEngine.Constants.providerOverhead)
        #expect(large.availableTokens > 198_000)
        #expect(small.maxTokens == 8_192)
        #expect(large.maxTokens == 200_000)
    }

    @Test("Rejects a context window smaller than the output reserve")
    func rejectsContextWindowSmallerThanReserve() {
        #expect(throws: TokenBudgetError.self) {
            try TurnEngine.makeTokenBudget(contextWindowTokens: 100, maxOutputTokens: 4_096)
        }
    }

    @Test("Rejects non-positive context window")
    func rejectsNonPositiveContextWindow() {
        #expect(throws: TokenBudgetError.nonPositiveContextWindow(0)) {
            try TurnEngine.makeTokenBudget(contextWindowTokens: 0, maxOutputTokens: 512)
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
        let budget = try TurnEngine.makeTokenBudget(
            contextWindowTokens: config.contextWindowTokens,
            maxOutputTokens: 512
        )
        #expect(budget.maxTokens == 32_000)
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

    // MARK: - History budget derivation (#288)

    @Test("The history budget scales with the model context window")
    func historyBudgetScalesWithContextWindow() {
        let small = PromptHistoryOptimizer.historyBudget(contextWindowTokens: 8_192)
        let medium = PromptHistoryOptimizer.historyBudget(contextWindowTokens: 128_000)
        let large = PromptHistoryOptimizer.historyBudget(contextWindowTokens: 1_000_000)

        let reserve = PromptHistoryOptimizer.nonHistoryTokenReserve
        #expect(small == 8_192 - reserve)
        #expect(medium == 128_000 - reserve)
        #expect(large == 1_000_000 - reserve)
        #expect(small < medium)
        #expect(medium < large)
    }

    @Test("The history budget subtracts the response reserve and measured non-history tiers")
    func historyBudgetSubtractsReserveAndNonHistory() {
        let budget = PromptHistoryOptimizer.historyBudget(
            contextWindowTokens: 128_000,
            responseReserve: 4_608,
            nonHistoryTokens: 2_000
        )
        #expect(budget == 128_000 - 4_608 - 2_000)
    }

    @Test("The history budget never goes negative")
    func historyBudgetNeverNegative() {
        #expect(PromptHistoryOptimizer.historyBudget(contextWindowTokens: 1_000, responseReserve: 4_608) == 0)
    }

    @Test("Assembly trims history to the context-window-derived budget")
    func assemblyTrimsHistoryToDerivedBudget() async throws {
        let history = (0 ..< 200).map { index in
            Message(content: "message-\(index) " + String(repeating: "x", count: 400), role: .user)
        }

        func renderedLength(contextWindow: Int) async throws -> Int {
            let request = LLMPromptRequest(
                userQuery: "hello",
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: nil
            )
            let prompt = try await PromptAssembler.assemble(
                request,
                options: PromptAssemblyOptions(tokenBudget: TokenBudget(maxTokens: contextWindow))
            )
            return prompt.sectionsByID["chat_history"]?.count ?? 0
        }

        let small = try await renderedLength(contextWindow: 8_192)
        let large = try await renderedLength(contextWindow: 1_000_000)
        #expect(small < large)
    }
}
