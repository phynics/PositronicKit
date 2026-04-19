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

@Suite("AssembledPrompt")
struct AssembledPromptTests {
    @Test("Assembled prompt sorts resolved sections by priority descending")
    func initializationSortsByPriorityDesc() async {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = AssembledPrompt(resolvedSections: [sec1.resolve()[0], sec2.resolve()[0]])
        let resolved = prompt.resolveSections()

        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
        #expect(resolved[1].id == "s1")
    }

    @Test("Assembled prompt renders non-empty sections in order")
    func render() async {
        let prompt = AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "First block").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: nil).resolve()[0],
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Second block").resolve()[0],
        ])

        let result = await prompt.render()
        #expect(result == "First block\n\n---\n\nSecond block")
    }

    @Test("Assembled prompt renderAll skips empty content")
    func renderAll() async {
        let prompt = AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "Val1").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: "").resolve()[0],
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Val2").resolve()[0],
        ])

        let context = await prompt.renderAll()
        #expect(context.count == 2)
        #expect(context["s1"] == "Val1")
        #expect(context["s3"] == "Val2")
        #expect(context["s2"] == nil)
    }

    @Test("Assembled prompt render with partial preRendered falls back to live rendering")
    func renderWithPartialPreRenderedFallsBackToLiveRendering() async {
        let prompt = AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "Cached").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: "Rendered").resolve()[0],
        ])

        let result = await prompt.render(preRendered: ["s1": "Cached"])

        #expect(result == "Cached\n\n---\n\nRendered")
    }

    @Test("Assembled prompt estimatedTokens sums resolved tokens")
    func estimatedTokens() {
        let prompt = AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 50, text: "A").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 100, text: "B").resolve()[0],
        ])

        #expect(prompt.estimatedTokens == 150)
    }

    @Test("Assembled prompt sorts by cache policy before priority")
    func cachePolicySorting() async {
        let volatileHigh = DummyPromptSection(id: "volatileHigh", priority: 100, estimatedTokens: 0, text: "V", cachePolicy: .volatile)
        let semiStableLow = DummyPromptSection(id: "semiStableLow", priority: 1, estimatedTokens: 0, text: "S", cachePolicy: .semiStable)
        let stableMedium = DummyPromptSection(id: "stableMedium", priority: 50, estimatedTokens: 0, text: "M", cachePolicy: .stable)
        let stableHigh = DummyPromptSection(id: "stableHigh", priority: 100, estimatedTokens: 0, text: "H", cachePolicy: .stable)

        let prompt = AssembledPrompt(resolvedSections: [
            volatileHigh.resolve()[0],
            semiStableLow.resolve()[0],
            stableMedium.resolve()[0],
            stableHigh.resolve()[0],
        ])
        let resolved = prompt.resolveSections()

        #expect(resolved.map(\.id) == ["stableHigh", "stableMedium", "semiStableLow", "volatileHigh"])
    }
}
