import Testing
import Foundation
@testable import MonadPrompt

struct MockContextSection: ContextSection {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let strategy: CompressionStrategy
    let type: ContextSectionType
    let renderedContent: String

    init(id: String, priority: Int, estimatedTokens: Int, strategy: CompressionStrategy = .keep, type: ContextSectionType = .text, renderedContent: String = "content") {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.strategy = strategy
        self.type = type
        self.renderedContent = renderedContent
    }

    func render() async -> String? { return renderedContent }

    func render(constrainedTo tokens: Int?) async -> String? {
        if let tokens = tokens {
            return String(renderedContent.prefix(tokens))
        }
        return renderedContent
    }

    func constrained(to tokens: Int) -> ContextSection {
        return ConstrainedSection(wrapped: self, limit: tokens)
    }
}

@Suite final class TokenBudgetTests {

    @Test

    func testApplyUnderBudget() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 200) // available = 800
        let sections: [ContextSection] = [
            MockContextSection(id: "s1", priority: 1, estimatedTokens: 400),
            MockContextSection(id: "s2", priority: 2, estimatedTokens: 300)
        ] // total = 700

        let result = await budget.apply(to: sections)
        #expect(result.count == 2)
        #expect(result[0].id == "s1")
        #expect(result[1].id == "s2")
    }

    @Test

    func testApplyOverBudgetPrioritizesHighPriority() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0) // available = 1000
        let sections: [ContextSection] = [
            MockContextSection(id: "low", priority: 1, estimatedTokens: 800, strategy: .drop),
            MockContextSection(id: "high", priority: 2, estimatedTokens: 800, strategy: .drop)
        ]

        // Only "high" should be kept because it takes 800 tokens, leaving 200, so "low" is dropped.
        let result = await budget.apply(to: sections)
        #expect(result.count == 1)
        #expect(result[0].id == "high")
    }

    @Test

    func testApplyKeepExceedsBudget() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0) // available = 1000
        let sections: [ContextSection] = [
            MockContextSection(id: "keep1", priority: 2, estimatedTokens: 800, strategy: .keep),
            MockContextSection(id: "keep2", priority: 1, estimatedTokens: 800, strategy: .keep)
        ]

        // .keep sections are unconditionally kept even if they exceed budget
        let result = await budget.apply(to: sections)
        #expect(result.count == 2)
        #expect(result[0].id == "keep1")
        #expect(result[1].id == "keep2")
    }

    @Test

    func testApplyTruncateSqueezesToRemaining() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0) // available = 1000
        let sections: [ContextSection] = [
            MockContextSection(id: "keep", priority: 2, estimatedTokens: 800, strategy: .keep),
            MockContextSection(id: "truncate", priority: 1, estimatedTokens: 500, strategy: .truncate(tail: true))
        ]

        // "truncate" should be constrained to 200 tokens
        let result = await budget.apply(to: sections)
        #expect(result.count == 2)
        #expect(result[0].id == "keep")
        #expect(result[1].id == "truncate")
        #expect(result[1].estimatedTokens == 200) // constrained token estimation should reflect the limit

        let rendered = await result[1].render()
        // Wait, the rendered string length is the text length, not necessarily tokens. Our mock just does prefix lengths.
        #expect(rendered?.count == 7) // "content" has 7 characters, min(7, 200) = 7
    }

    @Test

    func testApplyDropWithoutBudget() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0) // available = 1000
        let sections: [ContextSection] = [
            MockContextSection(id: "s1", priority: 2, estimatedTokens: 1000, strategy: .keep),
            MockContextSection(id: "drop", priority: 1, estimatedTokens: 500, strategy: .drop),
            MockContextSection(id: "truncate_dropped", priority: 0, estimatedTokens: 500, strategy: .truncate(tail: true))
        ]

        // "s1" takes all budget (1000), leaving 0.
        // "drop" fails to fit and is dropped.
        // "truncate_dropped" fails to fit and has 0 remaining budget, so it is also dropped.
        let result = await budget.apply(to: sections)
        #expect(result.count == 1)
        #expect(result[0].id == "s1")
    }

    @Test

    func testApplySummarizeFallsBackToDrop() async {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0) // available = 1000
        let sections: [ContextSection] = [
            MockContextSection(id: "s1", priority: 2, estimatedTokens: 800, strategy: .keep),
            MockContextSection(id: "summarize", priority: 1, estimatedTokens: 500, strategy: .summarize)
        ]

        // .summarize drops entirely because there is not enough space.
        let result = await budget.apply(to: sections)
        #expect(result.count == 1)
        #expect(result[0].id == "s1")
    }
}
