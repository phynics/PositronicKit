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
    @Test("Prompt keeps declarative sections and assembles them on demand")
    func promptAssemblesSections() async {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = Prompt(sections: [sec1, sec2])
        #expect(prompt.sections.count == 2)

        let resolved = prompt.assemble().resolveSections()

        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
        #expect(resolved[1].id == "s1")
    }

    @Test("Prompt builder preserves composed sections for later assembly")
    func promptBuilderInitialization() async {
        let prompt = Prompt {
            DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "A")
            DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "B")
        }

        #expect(prompt.sections.count == 1)

        let resolved = prompt.assemble().resolveSections()
        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
    }
}
