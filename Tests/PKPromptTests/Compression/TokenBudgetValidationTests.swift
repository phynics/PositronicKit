import Foundation
import Testing
@testable import PKPrompt

private struct MockPrimitiveSection: PromptPrimitive {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let compression: CompressionStrategy
    let type: PromptSectionType
    let renderedContent: String

    init(
        id: String,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy = .keep,
        type: PromptSectionType = .text,
        renderedContent: String = "content"
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.compression = compression
        self.type = type
        self.renderedContent = renderedContent
    }

    func renderContent() async -> String? {
        renderedContent
    }
}

private func resolve(_ sections: [MockPrimitiveSection]) -> [PromptSection] {
    sections.map { $0.makeSection() }
}

@Suite("TokenBudget validation")
struct TokenBudgetValidationTests {
    @Test("availableTokens is contextWindow minus outputReserve")
    func availableTokensIsMaxMinusReserve() throws {
        let budget = try TokenBudget(contextWindow: 128_000, outputReserve: 4_608)
        #expect(budget.maxTokens == 128_000)
        #expect(budget.reserveForResponse == 4_608)
        #expect(budget.availableTokens == 123_392)
    }

    @Test("A 512-token output reserve does not destructively compress a 128k context window")
    func smallOutputReserveLeavesLargePromptBudget() throws {
        let budget = try TokenBudget(contextWindow: 128_000, outputReserve: 512)
        #expect(budget.availableTokens > 127_000)
    }

    @Test("Rejects non-positive context window")
    func rejectsNonPositiveContextWindow() {
        #expect(throws: TokenBudgetError.nonPositiveContextWindow(0)) {
            try TokenBudget(contextWindow: 0, outputReserve: 10)
        }
        #expect(throws: TokenBudgetError.nonPositiveContextWindow(-1)) {
            try TokenBudget(contextWindow: -1, outputReserve: 10)
        }
    }

    @Test("Rejects negative output reserve")
    func rejectsNegativeOutputReserve() {
        #expect(throws: TokenBudgetError.negativeOutputReserve(-1)) {
            try TokenBudget(contextWindow: 1000, outputReserve: -1)
        }
    }

    @Test("Rejects output reserve that consumes the entire context window")
    func rejectsReserveExceedingContextWindow() {
        #expect(throws: TokenBudgetError.outputReserveExceedsContextWindow(contextWindow: 512, reserve: 512)) {
            try TokenBudget(contextWindow: 512, outputReserve: 512)
        }
        #expect(throws: TokenBudgetError.outputReserveExceedsContextWindow(contextWindow: 512, reserve: 1000)) {
            try TokenBudget(contextWindow: 512, outputReserve: 1000)
        }
    }

    @Test("TokenBudgetError conforms to PKError with stable domain and codes")
    func tokenBudgetErrorIdentity() {
        #expect(TokenBudgetError.nonPositiveContextWindow(0).errorDomain == "com.positronickit.core.prompt")
        #expect(TokenBudgetError.nonPositiveContextWindow(0).errorCode == 1101)
        #expect(TokenBudgetError.negativeOutputReserve(-1).errorCode == 1102)
        #expect(
            TokenBudgetError.outputReserveExceedsContextWindow(contextWindow: 1, reserve: 2).errorCode
                == 1103
        )
        #expect(TokenBudgetError.nonPositiveContextWindow(0).userFriendlyMessage.contains("context window") == true)
        #expect(TokenBudgetError.nonPositiveContextWindow(0).remediation != nil)
    }

    @Test("Budget-invariant: a prompt under the available budget is not compressed")
    func promptUnderBudgetIsNotCompressed() async throws {
        let budget = try TokenBudget(contextWindow: 128_000, outputReserve: 512)
        let sections = resolve([
            MockPrimitiveSection(id: "ctx", priority: 1, estimatedTokens: 50_000, renderedContent: String(repeating: "x", count: 50_000)),
        ])
    let result = try await budget.result(for: sections).sections
        #expect(result.count == 1)
        #expect(result[0].estimatedTokens == 50_000)
    }
}
