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
    @Test("AnyPrompt.build wraps builder content in a transparent prompt container")
    func anyPromptBuild() {
        let prompt = AnyPrompt.build {
            DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "A")
            DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "B")
        }

        #expect(type(of: prompt) == AnyPrompt.self)
        #expect(prompt.sections.count == 1)
        #expect(type(of: prompt.sections[0]) == PromptBlock<DummyPromptSection, DummyPromptSection>.self)
        #expect(try! prompt.assembledPrompt().resolvedSections.map { $0.id } == ["s2", "s1"])
    }

    @Test("Prompt composites assemble directly without a wrapper")
    func promptCompositesAssembleDirectly() async {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = AnyPrompt([sec1, sec2])
        #expect(prompt.sections.count == 2)

        let resolved = try! prompt.assembledPrompt().resolvedSections

        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
        #expect(resolved[1].id == "s1")
    }

    @Test("AnyPrompt builder stores the lowered builder output")
    func promptBuilderInitialization() async {
        let prompt = AnyPrompt {
            DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "A")
            DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "B")
        }

        #expect(prompt.sections.count == 1)
        #expect(type(of: prompt.sections[0]) == PromptBlock<DummyPromptSection, DummyPromptSection>.self)

        let resolved = try! prompt.assembledPrompt().resolvedSections
        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
    }
}
