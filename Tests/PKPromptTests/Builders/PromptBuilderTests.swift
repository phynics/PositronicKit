import Foundation
import Testing
@testable import PKPrompt

@Suite("PromptBuilder")
struct PromptBuilderTests {
    struct MockSection: PromptLeaf {
        let id: String
        let priority: Int
        let content: String
        let compression: CompressionStrategy = .keep
        let type: PromptSectionType = .text

        var estimatedTokens: Int { content.count }

        func renderContent() async -> String? {
            content
        }
    }

    private func buildComposite(@PromptBuilder _ content: () -> PromptGroup) -> PromptGroup {
        content()
    }

    @Test("Builder composes multiple sections")
    func exampleBuilder() async {
        let prompt = Prompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let assembled = prompt.assemble()
        let sections = assembled.resolveSections()
        #expect(sections.count == 2)
        #expect(sections[0].id == "2")
        #expect(sections[1].id == "1")

        let rendered = await assembled.render()
        #expect(rendered.contains("High Priority"))
        #expect(rendered.contains("Low Priority"))
    }

    @Test("Builder supports conditionals")
    func conditionals() async {
        let includeSecret = false
        let includePublic = true

        let sections = PromptGroup {
            if includeSecret {
                MockSection(id: "secret", priority: 50, content: "Secret")
            }

            if includePublic {
                MockSection(id: "public", priority: 50, content: "Public")
            }
        }.assemble().resolveSections()
        #expect(sections.count == 1)
        #expect(sections[0].id == "public")
    }

    @Test("Builder supports loops")
    func loop() async {
        let items = ["A", "B", "C"]

        let prompt = Prompt {
            for item in items {
                MockSection(id: item, priority: 50, content: item)
            }
        }

        let sections = prompt.assemble().resolveSections()
        #expect(sections.count == 3)
    }

    @Test("Builder lowers blocks to PromptGroup")
    func blockLowersToGroup() {
        let composite = buildComposite {
            MockSection(id: "1", priority: 10, content: "One")
            MockSection(id: "2", priority: 20, content: "Two")
        }

        #expect(composite.sections.count == 2)
    }

    @Test("Group alias composes nested prompt content")
    func groupAliasComposesNestedPromptContent() {
        let prompt = Prompt {
            Group {
                MockSection(id: "1", priority: 10, content: "One")
                MockSection(id: "2", priority: 20, content: "Two")
            }
        }

        #expect(prompt.assemble().resolveSections().map(\.id) == ["2", "1"])
    }

    @Test("Builder lowers conditionals to PromptConditional")
    func conditionalLowersToConditionalComposite() {
        let composite = buildComposite {
            if true {
                MockSection(id: "1", priority: 10, content: "One")
            } else {
                MockSection(id: "2", priority: 20, content: "Two")
            }
        }

        #expect(composite.sections.count == 1)
        #expect(composite.sections.first is PromptConditional)
    }

    @Test("Builder lowers loops to PromptForEach")
    func loopLowersToForEachComposite() {
        let items = ["A", "B", "C"]

        let composite = buildComposite {
            for item in items {
                MockSection(id: item, priority: 50, content: item)
            }
        }

        #expect(composite.sections.count == 1)
        #expect(composite.sections.first is PromptForEach)
    }

    @Test("Builder lowers optional branches to PromptOptionalFallback")
    func optionalLowersToOptionalFallbackComposite() {
        let composite = buildComposite {
            if false {
                MockSection(id: "hidden", priority: 50, content: "Hidden")
            }
        }

        #expect(composite.sections.count == 1)
        #expect(composite.sections.first is PromptOptionalFallback)
    }
}
