import Foundation
import Testing
@testable import PKPrompt

@Suite("ContextBuilder")
struct ContextBuilderTests {
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

    @Test("Builder composes multiple sections")
    func exampleBuilder() async {
        let prompt = Prompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let sections = await prompt.resolveSections()
        #expect(sections.count == 2)
        #expect(sections[0].id == "2")
        #expect(sections[1].id == "1")

        let rendered = await prompt.render()
        #expect(rendered.contains("High Priority"))
        #expect(rendered.contains("Low Priority"))
    }

    @Test("Builder supports conditionals")
    func conditionals() async {
        let includeSecret = false
        let includePublic = true

        let prompt = Prompt {
            if includeSecret {
                MockSection(id: "secret", priority: 50, content: "Secret")
            }

            if includePublic {
                MockSection(id: "public", priority: 50, content: "Public")
            }
        }

        let sections = await prompt.resolveSections()
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

        let sections = await prompt.resolveSections()
        #expect(sections.count == 3)
    }
}
