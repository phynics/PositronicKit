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

    struct IdentifiableItem: Identifiable, Sendable {
        let id: String
        let content: String
    }

    struct KeyedItem: Sendable {
        let key: String
        let content: String
    }

    private func buildComposite<Content: Prompt>(@PromptBuilder _ content: () -> Content) -> Content {
        content()
    }

    @Test("Builder composes multiple sections")
    func exampleBuilder() async {
        let prompt = AnyPrompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let assembled = try! prompt.assembledPrompt()
        let sections = assembled.resolvedSections
        #expect(sections.count == 2)
        #expect(sections[0].id == "2")
        #expect(sections[1].id == "1")

        let rendered = await assembled.rendered().string
        #expect(rendered.contains("High Priority"))
        #expect(rendered.contains("Low Priority"))
    }

    @Test("Builder supports conditionals")
    func conditionals() async {
        let includeSecret = false
        let includePublic = true

        let sections = try! AnyPrompt {
            if includeSecret {
                MockSection(id: "secret", priority: 50, content: "Secret")
            }

            if includePublic {
                MockSection(id: "public", priority: 50, content: "Public")
            }
        }.assembledPrompt().resolvedSections
        #expect(sections.count == 1)
        #expect(sections[0].id == "public")
    }

    @Test("Builder supports loops")
    func loop() async {
        let items = ["A", "B", "C"]

        let prompt = AnyPrompt {
            for item in items {
                MockSection(id: item, priority: 50, content: item)
            }
        }

        let sections = prompt.resolvedSections()
        #expect(sections.count == 3)
    }

    @Test("Builder preserves typed block structure")
    func blockPreservesTypedStructure() {
        let composite = buildComposite {
            MockSection(id: "1", priority: 10, content: "One")
            MockSection(id: "2", priority: 20, content: "Two")
        }

        #expect(type(of: composite) == PromptBlock<MockSection, MockSection>.self)
    }

    @Test("AnyPrompt composes nested prompt content")
    func anyPromptComposesNestedPromptContent() {
        let prompt = AnyPrompt {
            MockSection(id: "1", priority: 10, content: "One")
            MockSection(id: "2", priority: 20, content: "Two")
        }

        #expect(try! prompt.assembledPrompt().resolvedSections.map { $0.id } == ["2", "1"])
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

        #expect(type(of: composite) == PromptConditional<MockSection, MockSection>.self)
    }

    @Test("Builder lowers loops to PromptForEach")
    func loopLowersToForEachComposite() {
        let items = ["A", "B", "C"]

        let composite = buildComposite {
            for item in items {
                MockSection(id: item, priority: 50, content: item)
            }
        }

        #expect(type(of: composite) == PromptForEach<MockSection>.self)
    }

    @Test("PromptForEach supports Identifiable data")
    func forEachSupportsIdentifiableData() {
        let items = [
            IdentifiableItem(id: "a", content: "Alpha"),
            IdentifiableItem(id: "b", content: "Beta"),
        ]

        let composite = PromptForEach(items) { item in
            MockSection(id: item.id, priority: 50, content: item.content)
        }

        #expect(try! composite.assembledPrompt().resolvedSections.map { $0.id } == ["a", "b"])
    }

    @Test("PromptForEach supports explicit id key paths")
    func forEachSupportsExplicitIDKeyPath() {
        let items = [
            KeyedItem(key: "a", content: "Alpha"),
            KeyedItem(key: "b", content: "Beta"),
        ]

        let composite = PromptForEach(items, id: \.key) { item in
            MockSection(id: item.key, priority: 50, content: item.content)
        }

        #expect(try! composite.assembledPrompt().resolvedSections.map { $0.id } == ["a", "b"])
    }

    @Test("PromptForEach ids only stabilize paths and do not replace leaf ids")
    func forEachIDsDoNotOverrideLeafIdentity() {
        let items = [
            KeyedItem(key: "a", content: "Alpha"),
            KeyedItem(key: "b", content: "Beta"),
        ]

        let composite = PromptForEach(items, id: \.key) { item in
            MockSection(id: "shared", priority: 50, content: item.content)
        }

        #expect(throws: AssembledPrompt.ValidationError.duplicateSectionIDs(["shared"])) {
            try AssembledPrompt(resolvedSections: composite.resolvedSections())
        }
    }

    @Test("Builder lowers optional branches to PromptOptional")
    func optionalLowersToPromptOptionalComposite() {
        let composite = buildComposite {
            if false {
                MockSection(id: "hidden", priority: 50, content: "Hidden")
            }
        }

        #expect(type(of: composite) == PromptOptional<MockSection, EmptySection>.self)
    }
}
