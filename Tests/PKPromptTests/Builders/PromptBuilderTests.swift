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
            TextPrompt("Low Priority", id: "1", priority: 10)
            TextPrompt("High Priority", id: "2", priority: 100)
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
                TextPrompt("Secret", id: "secret")
            }

            if includePublic {
                TextPrompt("Public", id: "public")
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
                TextPrompt(item.content, id: item.id)
            }
        }

        let sections = try! prompt.assemblePrompt().sections
        #expect(sections.map(\.id) == ["A", "B", "C"])
        #expect(sections[0].path.contains("item_0"))
        #expect(sections[1].path.contains("item_1"))
        #expect(sections[2].path.contains("item_2"))
        #expect(sections.map { $0.path.suffix(2) } == [["volatile", "A"], ["volatile", "B"], ["volatile", "C"]])
    }

    @Test("PromptForEach uses stable path components from element ids")
    func identifiedLoopUsesStablePaths() {
        let items = [
            IdentifiableItem(id: "note-a", content: "Alpha"),
            IdentifiableItem(id: "note-b", content: "Beta"),
        ]

        let prompt = AnyPrompt {
            PromptForEach(items) { item in
                TextPrompt(item.content, id: "leaf-\(item.id)")
            }
        }

        let sections = try! prompt.assemblePrompt().sections
        #expect(sections[0].path.contains("note-a"))
        #expect(sections[1].path.contains("note-b"))
        #expect(sections.map { $0.path.suffix(2) } == [["volatile", "leaf-note-a"], ["volatile", "leaf-note-b"]])
    }

    @Test("PromptForEach preserves element-based paths across reordering")
    func identifiedLoopPathsStayStableAcrossReordering() {
        let original = [
            IdentifiableItem(id: "note-a", content: "Alpha"),
            IdentifiableItem(id: "note-b", content: "Beta"),
        ]
        let reordered = [original[1], original[0]]

        let originalSections = try! AnyPrompt {
            PromptForEach(original, id: \.id) { item in
                TextPrompt(item.content, id: "leaf-\(item.id)")
            }
        }.assemblePrompt().sections

        let reorderedSections = try! AnyPrompt {
            PromptForEach(reordered, id: \.id) { item in
                TextPrompt(item.content, id: "leaf-\(item.id)")
            }
        }.assemblePrompt().sections

        let originalPaths = Dictionary(uniqueKeysWithValues: originalSections.map { ($0.id, $0.path) })
        let reorderedPaths = Dictionary(uniqueKeysWithValues: reorderedSections.map { ($0.id, $0.path) })
        #expect(originalPaths == reorderedPaths)
    }

    @Test("PromptForEach supports closure-based stable ids")
    func closureBasedStableIDs() {
        let items = [
            IdentifiableItem(id: "a", content: "Alpha"),
            IdentifiableItem(id: "b", content: "Beta"),
        ]

        let sections = try! AnyPrompt {
            PromptForEach(items, id: { "note-\($0.id)" }) { item in
                TextPrompt(item.content, id: item.id)
            }
        }.assemblePrompt().sections

        #expect(sections[0].path.contains("note-a"))
        #expect(sections[1].path.contains("note-b"))
        #expect(sections.map(\.id) == ["a", "b"])
    }

    @Test("PromptBuilder convenience forwards to stable foreach")
    func promptBuilderConvenienceForEach() {
        let items = [
            IdentifiableItem(id: "a", content: "Alpha"),
            IdentifiableItem(id: "b", content: "Beta"),
        ]

        let sections = try! AnyPrompt {
            PromptBuilder.forEach(items, id: \.id) { item in
                TextPrompt(item.content, id: item.id)
            }
        }.assemblePrompt().sections

        #expect(sections.map(\.id) == ["a", "b"])
        #expect(sections[0].path.contains("a"))
        #expect(sections[1].path.contains("b"))
    }

    @Test("ForEach spelling is available inside prompt builders")
    func forEachSpellingWithinPromptBuilder() {
        let items = [
            IdentifiableItem(id: "x", content: "Ex"),
            IdentifiableItem(id: "y", content: "Why"),
        ]

        let sections = try! AnyPrompt {
            ForEach(items) { item in
                TextPrompt(item.content, id: item.id)
            }
        }.assemblePrompt().sections

        #expect(sections.map(\.id) == ["x", "y"])
        #expect(sections[0].path.contains("x"))
        #expect(sections[1].path.contains("y"))
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

        let sections = try! AnyPrompt {
            TextPrompt("Base", id: "base")
            if includeExtra {
                TextPrompt("Extra", id: "extra")
            }
        }.assemblePrompt().sections

        #expect(sections.map(\.id) == ["base"])
    }
}
