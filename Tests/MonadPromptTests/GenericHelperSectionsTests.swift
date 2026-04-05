import Testing
import Foundation
@testable import MonadPrompt

@Suite final class GenericHelperSectionsTests {

    @Test

    func testTextSectionInitialization() {
        let section = TextSection(
            id: "system",
            text: "You are an AI.",
            priority: 100,
            strategy: .drop,
            estimatedTokens: 5
        )

        #expect(section.id == "system")
        #expect(section.text == "You are an AI.")
        #expect(section.priority == 100)

        if case .drop = section.strategy { /* expected */ } else {
            Issue.record("Wrong strategy")
        }

        if case .text = section.type { /* expected */ } else {
            Issue.record("Wrong type")
        }

        #expect(section.estimatedTokens == 5)
    }

    @Test

    func testTextSectionDefaultEstimatedTokens() {
        // Fallback uses string count / 4
        let text = String(repeating: "char", count: 100) // 400 characters
        let section = TextSection(id: "t1", text: text)
        #expect(section.estimatedTokens == 100)
    }

    @Test

    func testTextSectionRender() async {
        let section = TextSection(id: "t1", text: "Hello")
        let rendered = await section.render()
        #expect(rendered == "Hello")
    }

    @Test

    func testTextSectionRenderEmptyReturnsNil() async {
        let section = TextSection(id: "t1", text: "")
        let rendered = await section.render()
        #expect(rendered == nil)
    }

    @Test

    func testEmptySection() async {
        let section = EmptySection()

        #expect(section.id == "empty")
        #expect(section.priority == 0)
        #expect(section.estimatedTokens == 0)

        let rendered = await section.render()
        #expect(rendered == nil)
    }
}
