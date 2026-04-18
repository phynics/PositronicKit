import Foundation
import Testing
@testable import PKPrompt

@Suite("Generic helper sections")
struct GenericHelperSectionsTests {
    @Test("TextSection stores explicit configuration")
    func textSectionInitialization() {
        let section = TextSection(
            id: "system",
            text: "You are an AI.",
            priority: 100,
            compression: .drop,
            estimatedTokens: 5
        )

        #expect(section.id == "system")
        #expect(section.text == "You are an AI.")
        #expect(section.priority == 100)
        #expect(section.compression == .drop)
        #expect(section.type == .text)
        #expect(section.estimatedTokens == 5)
    }

    @Test("TextSection derives estimated tokens from text")
    func textSectionDefaultEstimatedTokens() {
        let text = String(repeating: "char", count: 100)
        let section = TextSection(id: "t1", text: text)
        #expect(section.estimatedTokens == 100)
    }

    @Test("TextSection renders non-empty content")
    func textSectionRender() async {
        let section = TextSection(id: "t1", text: "Hello")
        let resolved = section.resolve(in: PromptResolutionContext())[0]
        #expect(await resolved.render() == "Hello")
    }

    @Test("TextSection renders nil for empty content")
    func textSectionRenderEmptyReturnsNil() async {
        let section = TextSection(id: "t1", text: "")
        let resolved = section.resolve(in: PromptResolutionContext())[0]
        #expect(await resolved.render() == nil)
    }

    @Test("EmptySection resolves to no leaves")
    func emptySection() {
        let section = EmptySection()
        #expect(section.resolve(in: PromptResolutionContext()).isEmpty)
    }
}
