import Foundation
import Testing
@testable import PKPrompt

private struct DummyPromptSection: PromptLeaf {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let text: String?
    let cachePolicy: CachePolicy

    init(
        id: String,
        priority: Int,
        estimatedTokens: Int,
        text: String?,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.text = text
        self.cachePolicy = cachePolicy
    }

    func renderContent() async -> String? {
        text
    }
}

@Suite("Prompt")
struct PromptTests {
    @Test("Prompt resolves sections sorted by priority descending")
    func promptInitializationSortsByPriorityDesc() async {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = Prompt(sections: [sec1, sec2])
        let resolved = await prompt.resolveSections()

        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
        #expect(resolved[1].id == "s1")
    }

    @Test("Prompt builder initializes composed sections")
    func promptContextBuilderInitialization() async {
        let prompt = Prompt {
            DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "A")
            DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "B")
        }

        let resolved = await prompt.resolveSections()
        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
    }

    @Test("Prompt renders non-empty sections in order")
    func promptRender() async {
        let prompt = Prompt {
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "First block")
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: nil)
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Second block")
        }

        let result = await prompt.render()
        #expect(result == "First block\n\n---\n\nSecond block")
    }

    @Test("Prompt renderAll skips empty content")
    func promptStructuredContext() async {
        let prompt = Prompt {
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "Val1")
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: "")
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Val2")
        }

        let context = await prompt.renderAll()
        #expect(context.count == 2)
        #expect(context["s1"] == "Val1")
        #expect(context["s3"] == "Val2")
        #expect(context["s2"] == nil)
    }

    @Test("Prompt estimatedTokens sums resolved tokens")
    func promptEstimatedTokens() {
        let prompt = Prompt {
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 50, text: "A")
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 100, text: "B")
        }

        #expect(prompt.estimatedTokens == 150)
    }

    @Test("Prompt resolves by cache policy before priority")
    func promptCachePolicySorting() async {
        let volatileHigh = DummyPromptSection(id: "volatileHigh", priority: 100, estimatedTokens: 0, text: "V", cachePolicy: .volatile)
        let semiStableLow = DummyPromptSection(id: "semiStableLow", priority: 1, estimatedTokens: 0, text: "S", cachePolicy: .semiStable)
        let stableMedium = DummyPromptSection(id: "stableMedium", priority: 50, estimatedTokens: 0, text: "M", cachePolicy: .stable)
        let stableHigh = DummyPromptSection(id: "stableHigh", priority: 100, estimatedTokens: 0, text: "H", cachePolicy: .stable)

        let prompt = Prompt(sections: [volatileHigh, semiStableLow, stableMedium, stableHigh])
        let resolved = await prompt.resolveSections()

        #expect(resolved.map(\.id) == ["stableHigh", "stableMedium", "semiStableLow", "volatileHigh"])
    }
}
