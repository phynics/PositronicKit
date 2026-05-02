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
        @PromptBuilder
        func build() -> some Prompt {
            TextPrompt("Low Priority", id: "1", priority: 10)
            TextPrompt("High Priority", id: "2", priority: 100)
        }

        let assembled = try! build().assemblePrompt()
        #expect(assembled.sections.map(\.id) == ["2", "1"])

        let rendered = await assembled.render()
        #expect(rendered.string.contains("High Priority"))
        #expect(rendered.string.contains("Low Priority"))
    }

    @Test("Builder supports conditionals")
    func conditionals() {
        let includeSecret = false
        let includePublic = true

        @PromptBuilder
        func build() -> some Prompt {
            if includeSecret {
                TextPrompt("Secret", id: "secret")
            }

            if includePublic {
                TextPrompt("Public", id: "public")
            }
        }

        let sections = try! build().assemblePrompt().sections

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

        @PromptBuilder
        func build() -> some Prompt {
            for item in items {
                TextPrompt(item.content, id: item.id)
            }
        }

        let sections = try! build().assemblePrompt().sections
        #expect(sections.map(\.id) == ["A", "B", "C"])
        #expect(sections.map { $0.path.suffix(2) } == [["volatile", "A"], ["volatile", "B"], ["volatile", "C"]])
    }

    @Test("Builder supports ForEach(data:) expressions")
    func forEachDataExpression() {
        let items = [
            IdentifiableItem(id: "note-a", content: "Alpha"),
            IdentifiableItem(id: "note-b", content: "Beta"),
        ]

        @PromptBuilder
        func build() -> some Prompt {
            ForEach(data: items) { item in
                TextPrompt(item.content, id: "leaf-\(item.id)")
            }
        }

        let sections = try! build().assemblePrompt().sections
        #expect(sections.map(\.id) == ["leaf-note-a", "leaf-note-b"])
    }

    @Test("Builder supports arrays of prompt expressions")
    func arrayExpression() {
        @PromptBuilder
        func build() -> some Prompt {
            [
                TextPrompt("One", id: "1"),
                TextPrompt("Two", id: "2"),
            ]
            if true {
                TextPrompt("Three", id: "3")
            }
        }

        let sections = try! build().assemblePrompt().sections
        #expect(sections.map(\.id) == ["1", "2", "3"])
    }

    @Test("Builder optional branches omit nil content")
    func optionalBranch() {
        let includeExtra = false

        @PromptBuilder
        func build() -> some Prompt {
            TextPrompt("Base", id: "base")
            if includeExtra {
                TextPrompt("Extra", id: "extra")
            }
        }

        let sections = try! build().assemblePrompt().sections

        #expect(sections.map(\.id) == ["base"])
    }
}
