import Foundation
@testable import PKPrompt
import Testing

struct DummySection: ContextSection {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let text: String?

    func render() async -> String? {
        return text
    }
}

final class PromptTests {
    @Test

    func promptInitializationSortsByPriorityDesc() {
        let sec1 = DummySection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummySection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        // Using array init
        let prompt = Prompt(sections: [sec1, sec2])

        #expect(prompt.sections.count == 2)
        #expect(prompt.sections[0].id == "s2") // Priority 100 first
        #expect(prompt.sections[1].id == "s1")
    }

    @Test

    func promptContextBuilderInitialization() {
        let prompt = Prompt {
            DummySection(id: "s1", priority: 1, estimatedTokens: 10, text: "A")
            DummySection(id: "s2", priority: 100, estimatedTokens: 10, text: "B")
        }

        #expect(prompt.sections.count == 2)
        #expect(prompt.sections[0].id == "s2") // Higher priority first
    }

    @Test

    func promptRender() async {
        let prompt = Prompt {
            DummySection(id: "s1", priority: 10, estimatedTokens: 10, text: "First block")
            DummySection(id: "s2", priority: 5, estimatedTokens: 10, text: nil) // Skipped
            DummySection(id: "s3", priority: 1, estimatedTokens: 10, text: "Second block")
        }

        let result = await prompt.render()
        let expected = "First block\n\n---\n\nSecond block"

        #expect(result == expected)
    }

    @Test

    func promptStructuredContext() async {
        let prompt = Prompt {
            DummySection(id: "s1", priority: 10, estimatedTokens: 10, text: "Val1")
            DummySection(id: "s2", priority: 5, estimatedTokens: 10, text: "") // Empty string is skipped
            DummySection(id: "s3", priority: 1, estimatedTokens: 10, text: "Val2")
        }

        let context = await prompt.renderAll()

        #expect(context.count == 2)
        #expect(context["s1"] == "Val1")
        #expect(context["s3"] == "Val2")
        #expect(context["s2"] == nil)
    }

    @Test

    func promptEstimatedTokens() {
        let prompt = Prompt {
            DummySection(id: "s1", priority: 10, estimatedTokens: 50, text: "A")
            DummySection(id: "s2", priority: 5, estimatedTokens: 100, text: "B")
        }

        #expect(prompt.estimatedTokens == 150)
    }

    struct PolicySection: ContextSection {
        let id: String
        let cachePolicy: CachePolicy
        let priority: Int

        var estimatedTokens: Int {
            0
        }

        func render() async -> String? {
            id
        }
    }

    @Test

    func promptCachePolicySorting() {
        let volatileHigh = PolicySection(id: "volatileHigh", cachePolicy: .volatile, priority: 100)
        let semiStableLow = PolicySection(id: "semiStableLow", cachePolicy: .semiStable, priority: 1)
        let stableMedium = PolicySection(id: "stableMedium", cachePolicy: .stable, priority: 50)
        let stableHigh = PolicySection(id: "stableHigh", cachePolicy: .stable, priority: 100)

        let prompt = Prompt(sections: [volatileHigh, semiStableLow, stableMedium, stableHigh])

        #expect(prompt.sections.count == 4)
        // Order: stableHigh (stable, 100) -> stableMedium (stable, 50) -> semiStableLow (semiStable, 1) -> volatileHigh (volatile, 100)
        #expect(prompt.sections[0].id == "stableHigh")
        #expect(prompt.sections[1].id == "stableMedium")
        #expect(prompt.sections[2].id == "semiStableLow")
        #expect(prompt.sections[3].id == "volatileHigh")
    }
}
