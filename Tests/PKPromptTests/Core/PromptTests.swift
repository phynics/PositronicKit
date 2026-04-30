import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt")
struct PromptTests {
    private func expectSections(_ sections: [PromptSection], ids: [String]) {
        #expect(sections.map(\.id) == ids)
    }

    @Test("AnyPrompt.build assembles builder content in prompt order")
    func anyPromptBuild() {
        let prompt = AnyPrompt.build {
            TextPrompt("A", id: "s1", priority: 1)
            TextPrompt("B", id: "s2", priority: 100)
        }

        expectSections(try! prompt.assemblePrompt().sections, ids: ["s2", "s1"])
    }

    @Test("AnyPrompt array initializer assembles directly")
    func promptCompositesAssembleDirectly() {
        let prompt = AnyPrompt([
            TextPrompt("Low", id: "s1", priority: 1),
            TextPrompt("High", id: "s2", priority: 100),
        ])

        let resolved = try! prompt.assemblePrompt().sections
        #expect(resolved.map(\.id) == ["s2", "s1"])
    }

    @Test("AnyPrompt builder initializer stores semantic prompt content")
    func promptBuilderInitialization() {
        let prompt = AnyPrompt {
            TextPrompt("A", id: "s1", priority: 1)
            TextPrompt("B", id: "s2", priority: 100)
        }

        let resolved = try! prompt.assemblePrompt().sections
        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
    }

    @Test("PromptBuilder returns structural prompt values before node lowering")
    func promptBuilderReturnsStructuralPromptValues() {
        @PromptBuilder
        func build() -> some Prompt {
            TextPrompt("A", id: "s1")
            TextPrompt("B", id: "s2")
        }

        let built = build()
        let prompt = built as? AnyPrompt

        #expect(prompt != nil)
        #expect(prompt?.prompts.count == 2)
        #expect(prompt?.prompts[0] is TextPrompt)
        #expect(prompt?.prompts[1] is TextPrompt)
    }

    @Test("Prompt resolves concrete sections directly in authored order")
    func promptResolvesConcreteSectionsDirectly() {
        let sections = AnyPrompt {
            TextPrompt("A", id: "s1", priority: 1)
            TextPrompt("B", id: "s2", priority: 100)
        }.resolveSections()

        #expect(sections.map(\.id) == ["s1", "s2"])
    }

    @Test("Prompt resolves sections with an explicit resolution context")
    func promptResolvesSectionsWithExplicitContext() {
        let sections = TextPrompt("A", id: "s1")
            .priority(.high)
            .cachePolicy(.stable)
            .resolveSections(in: PromptResolutionContext(ancestorPath: ["custom"]))

        #expect(sections.count == 1)
        #expect(sections[0].priority == PromptPriority.high.rawValue)
        #expect(sections[0].path == ["custom", "TextPrompt", "stable", "s1"])
    }
}
