import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt assembly")
struct PromptAssemblyTests {
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

    @Test("Prompt builders assemble without an extra wrapper")
    func builderAssemblesDirectly() async {
        let composite = AnyPrompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let prompt = try! composite.assembledPrompt()
        let sections = prompt.sections

        #expect(sections.count == 2)
        #expect(sections[0].id == "2")
        #expect(sections[1].id == "1")
    }

    @Test("Prompt render convenience uses assembled prompt ordering")
    func compositeRenderUsesAssembledPrompt() async {
        let composite = AnyPrompt {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let rendered = await composite.render()

        #expect(rendered == "High Priority\n\n---\n\nLow Priority")
    }
}
