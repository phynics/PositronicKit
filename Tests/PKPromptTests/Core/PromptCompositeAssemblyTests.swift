import Foundation
import Testing
@testable import PKPrompt

@Suite("PromptComposite assembly")
struct PromptCompositeAssemblyTests {
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

    @Test("Composite builders assemble without wrapping in Prompt")
    func builderAssemblesDirectly() async {
        let composite = PromptAny {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let prompt = composite.assembledPrompt()
        let sections = prompt.resolvedSections

        #expect(sections.count == 2)
        #expect(sections[0].id == "2")
        #expect(sections[1].id == "1")
    }

    @Test("Composite render convenience uses assembled prompt ordering")
    func compositeRenderUsesAssembledPrompt() async {
        let composite = PromptAny {
            MockSection(id: "1", priority: 10, content: "Low Priority")
            MockSection(id: "2", priority: 100, content: "High Priority")
        }

        let rendered = await composite.render()

        #expect(rendered == "High Priority\n\n---\n\nLow Priority")
    }
}
