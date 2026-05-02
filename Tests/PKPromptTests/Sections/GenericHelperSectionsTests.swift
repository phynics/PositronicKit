import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt helper sections")
struct GenericHelperSectionsTests {
    @Test("ContextPrompt stores explicit configuration")
    func contextPromptInitialization() {
        let section = try! TextPrompt(
            "You are an AI.",
            id: "system",
            priority: 100,
            compression: .drop,
            cachePolicy: .stable,
            estimatedTokens: 5
        ).assemblePrompt().sections[0]

        #expect(section.id == "system")
        #expect(section.priority == 100)
        #expect(section.compression == .drop)
        #expect(section.cachePolicy == .stable)
        #expect(section.type == .text)
        #expect(section.estimatedTokens == 5)
    }

    @Test("ContextPrompt renders non-empty content")
    func contextPromptRender() async {
        let section = try! TextPrompt("Hello", id: "t1").assemblePrompt().sections[0]
        #expect(await section.renderedContent()?.text == "Hello")
    }

    @Test("ContextPrompt renders nil for empty content")
    func contextPromptRenderEmptyReturnsNil() async {
        let section = try! TextPrompt("", id: "t1").assemblePrompt().sections[0]
        #expect(await section.renderedContent()?.text == nil)
    }

    @Test("EmptySection assembles to no leaves")
    func emptySection() {
        let prompt = AnyPrompt {
            EmptySection()
        }
        #expect(try! prompt.assemblePrompt().sections.isEmpty)
    }
}
