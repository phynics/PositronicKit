import Testing
import Foundation
@testable import MonadPrompt

@Suite final class ContextBuilderTests {

    struct MockSection: ContextSection {
        let id: String
        let priority: Int
        let content: String
        let strategy: CompressionStrategy = .keep
        let type: ContextSectionType = .text

        var estimatedTokens: Int { content.count }

        func render() async -> String? {
            return content
        }
    }

    @Test

    func testExampleBuilder() async {
        let prompt = Prompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        // Should be sorted by priority
        #expect(prompt.sections.count == 2)
        #expect(prompt.sections[0].id == "2")
        #expect(prompt.sections[1].id == "1")

        let rendered = await prompt.render()
        #expect(rendered.contains("High Priority"))
        #expect(rendered.contains("Low Priority"))
    }

    @Test

    func testConditionals() async {
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

        #expect(prompt.sections.count == 1)
        #expect(prompt.sections[0].id == "public")
    }

    @Test

    func testLoop() async {
        let items = ["A", "B", "C"]

        let prompt = Prompt {
            for item in items {
                MockSection(id: item, priority: 50, content: item)
            }
        }

        #expect(prompt.sections.count == 3)
    }
}
