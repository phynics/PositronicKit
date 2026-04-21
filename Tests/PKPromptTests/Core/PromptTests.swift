import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt")
struct PromptTests {
    @Test("AnyPrompt.build assembles builder content in prompt order")
    func anyPromptBuild() {
        let prompt = AnyPrompt.build {
            ContextPrompt("A", id: "s1", priority: 1)
            ContextPrompt("B", id: "s2", priority: 100)
        }

        #expect(try! prompt.assemblePrompt().sections.map(\.id) == ["s2", "s1"])
    }

    @Test("AnyPrompt array initializer assembles directly")
    func promptCompositesAssembleDirectly() {
        let prompt = AnyPrompt([
            ContextPrompt("Low", id: "s1", priority: 1),
            ContextPrompt("High", id: "s2", priority: 100),
        ])

        let resolved = try! prompt.assemblePrompt().sections
        #expect(resolved.map(\.id) == ["s2", "s1"])
    }

    @Test("AnyPrompt builder initializer stores semantic prompt content")
    func promptBuilderInitialization() {
        let prompt = AnyPrompt {
            ContextPrompt("A", id: "s1", priority: 1)
            ContextPrompt("B", id: "s2", priority: 100)
        }

        let resolved = try! prompt.assemblePrompt().sections
        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
    }
}
