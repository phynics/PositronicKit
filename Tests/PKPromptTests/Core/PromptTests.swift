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
        let prompt = built as? PromptTuple<TextPrompt, TextPrompt>

        #expect(prompt != nil)
        if let prompt {
            let node = prompt.makePromptNode()
            if case let .fork(children) = node?.nodeType {
                #expect(children.count == 2)
            } else {
                Issue.record("Expected fork node")
            }
        }
    }

    @Test("EmptyPrompt resolves to no sections")
    func emptyPromptResolvesToNoSections() {
        #expect(EmptyPrompt().resolveSections().isEmpty)
    }

    @Test("PromptBuilder supports conditional branches with different prompt types")
    func conditionalBranchesWithDifferentPromptTypes() {
        @PromptBuilder
        func build(includeSystem: Bool) -> some Prompt {
            if includeSystem {
                SystemPrompt("System")
            } else {
                EmptyPrompt()
            }
        }

        let included = try! build(includeSystem: true).assemblePrompt().sections
        let omitted = try! build(includeSystem: false).assemblePrompt().sections

        #expect(included.count == 1)
        #expect(included[0].role == .system)
        #expect(omitted.isEmpty)
    }

    @Test("SystemPrompt remains stable even inside a volatile wrapper")
    func systemPromptRemainsStableInsideVolatileWrapper() {
        let sections = SystemPrompt("System")
            .cachePolicy(.volatile)
            .resolveSections()

        #expect(sections.count == 1)
        #expect(sections[0].role == .system)
        #expect(sections[0].cachePolicy == .stable)
        #expect(sections[0].path == ["prompt", "SystemPrompt", "stable", "system"])
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
            .resolveSections(in: PromptBuildContext(ancestorPath: ["custom"]))

        #expect(sections.count == 1)
        #expect(sections[0].priority == PromptPriority.high.rawValue)
        #expect(sections[0].path == ["custom", "TextPrompt", "stable", "s1"])
    }
}
