import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt assembly")
struct PromptAssemblyTests {
    @Test("Prompt builders assemble without an extra wrapper")
    func builderAssemblesDirectly() {
        let composite = AnyPrompt {
            TextPrompt("Low Priority", id: "1", priority: 10)
            TextPrompt("High Priority", id: "2", priority: 100)
        }

        let prompt = try! composite.assemblePrompt()
        #expect(prompt.sections.map(\.id) == ["2", "1"])
    }

    @Test("Prompt render convenience uses assembled prompt ordering")
    func compositeRenderUsesAssembledPrompt() async {
        let composite = AnyPrompt {
            TextPrompt("Low Priority", id: "1", priority: 10)
            TextPrompt("High Priority", id: "2", priority: 100)
        }

        let rendered = await composite.renderToString()
        #expect(rendered == "High Priority\n\n---\n\nLow Priority")
    }
}
