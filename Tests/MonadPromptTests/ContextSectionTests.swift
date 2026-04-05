import Testing
import Foundation
@testable import MonadPrompt

struct MinimalSection: ContextSection {
    let id: String = "min"
    let priority: Int = 1
    let estimatedTokens: Int = 100

    func render() async -> String? {
        return "minimal text"
    }
}

@Suite final class ContextSectionTests {

    @Test

    func testDefaultImplementations() async {
        let section = MinimalSection()

        // Default strategy should be .keep
        if case .keep = section.strategy { /* expected */ } else {
            Issue.record("Default strategy should be .keep")
        }

        // Default type should be .text
        if case .text = section.type { /* expected */ } else {
            Issue.record("Default type should be .text")
        }

        // Default render(constrainedTo:) just calls render()
        let constrainedRender = await section.render(constrainedTo: 50)
        #expect(constrainedRender == "minimal text")
    }

    @Test

    func testConstrainedSection() async {
        let base = MinimalSection() // size 100
        let constrained = ConstrainedSection(wrapped: base, limit: 50)

        #expect(constrained.id == "min")
        #expect(constrained.priority == 1)
        #expect(constrained.estimatedTokens == 50) // capped by limit

        if case .keep = constrained.strategy { /* expected */ } else {
            Issue.record("Strategy must pass through")
        }

        // Nesting constraints
        let doublyConstrained = constrained.constrained(to: 30) as! ConstrainedSection
        #expect(doublyConstrained.limit == 30)
        #expect(doublyConstrained.estimatedTokens == 30)

        // If we constrain to a larger amount, limit should reflect the min
        let largerConstrained = doublyConstrained.constrained(to: 100) as! ConstrainedSection
        #expect(largerConstrained.limit == 30)
    }
}
