import Foundation
import Testing
@testable import PKPrompt

@Suite("PromptBuilder")
struct PromptBuilderTests {
    struct IdentifiableItem: Identifiable, Sendable {
        let id: String
        let content: String
    }

    @Test("Builder composes multiple sections")
    func exampleBuilder() async {
        let prompt = AnyPrompt {
            ContextPrompt("Low Priority", id: "1", priority: 10)
            ContextPrompt("High Priority", id: "2", priority: 100)
        }

        let assembled = try! prompt.assemblePrompt()
        #expect(assembled.sections.map(\.id) == ["2", "1"])

        let rendered = await assembled.render()
        #expect(rendered.string.contains("High Priority"))
        #expect(rendered.string.contains("Low Priority"))
    }

    @Test("Builder supports conditionals")
    func conditionals() {
        let includeSecret = false
        let includePublic = true

        let sections = try! AnyPrompt {
            if includeSecret {
                ContextPrompt("Secret", id: "secret")
            }

            if includePublic {
                ContextPrompt("Public", id: "public")
            }
        }.assemblePrompt().sections

        #expect(sections.count == 1)
        #expect(sections[0].id == "public")
    }

    @Test("Builder supports loops")
    func loop() {
        let items = [
            IdentifiableItem(id: "A", content: "Alpha"),
            IdentifiableItem(id: "B", content: "Beta"),
            IdentifiableItem(id: "C", content: "Gamma"),
        ]

        let prompt = AnyPrompt {
            for item in items {
                ContextPrompt(item.content, id: item.id)
            }
        }

        let sections = try! prompt.assemblePrompt().sections
        #expect(sections.map(\.id) == ["A", "B", "C"])
    }

    @Test("Builder supports arrays of prompt expressions")
    func arrayExpression() {
        @PromptBuilder
        func build() -> some Prompt {
            [
                ContextPrompt("One", id: "1"),
                ContextPrompt("Two", id: "2"),
            ]
            if true {
                ContextPrompt("Three", id: "3")
            }
        }

        let sections = try! build().assemblePrompt().sections
        #expect(sections.map(\.id) == ["1", "2", "3"])
    }

    @Test("Builder optional branches omit nil content")
    func optionalBranch() {
        let includeExtra = false

        let sections = try! AnyPrompt {
            ContextPrompt("Base", id: "base")
            if includeExtra {
                ContextPrompt("Extra", id: "extra")
            }
        }.assemblePrompt().sections

        #expect(sections.map(\.id) == ["base"])
    }
}
