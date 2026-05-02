import Foundation
import Testing
@testable import PKPrompt

private struct MinimalPromptPrimitive: PromptPrimitive {
    let id = "min"
    let priority = 1
    let estimatedTokens = 100

    func renderContent() async -> String? {
        "minimal text"
    }
}

private struct TruncatablePromptPrimitive: PromptPrimitive {
    let id = "truncate"
    let priority = 1
    let estimatedTokens = 100
    let compression: CompressionStrategy
    let text: String

    func renderContent() async -> String? {
        text
    }
}

@Suite("Prompt core")
struct PromptCoreTests {
    @Test("Prompt primitives use default traits")
    func defaultImplementations() async {
        let section = MinimalPromptPrimitive()
        let resolved = [section.makeSection()]

        #expect(resolved.count == 1)
        #expect(resolved[0].compression == .keep)
        #expect(resolved[0].type == .text)

        let constrainedRender = await resolved[0].renderedContent(constrainedTo: 50)?.text
        #expect(constrainedRender == "minimal text")
    }

    @Test("Concrete sections can be constrained")
    func concreteSectionConstraint() async {
        let base = MinimalPromptPrimitive().makeSection()
        let constrained = base.constrained(to: 50)

        #expect(constrained.id == "min")
        #expect(constrained.priority == 1)
        #expect(constrained.estimatedTokens == 50)
    }

    @Test("Truncate tail applies during constrained rendering")
    func truncateTailRendering() async {
        let resolved = TruncatablePromptPrimitive(
            compression: .truncate(tail: true),
            text: "abcdefghijklmnop"
        ).makeSection()

        let rendered = await resolved.renderedContent(constrainedTo: 2)?.text
        #expect(rendered == "abcd\n... [Truncated]")
    }

    @Test("Truncate head applies during constrained rendering")
    func truncateHeadRendering() async {
        let resolved = TruncatablePromptPrimitive(
            compression: .truncate(tail: false),
            text: "abcdefghijklmnop"
        ).makeSection()

        let rendered = await resolved.renderedContent(constrainedTo: 2)?.text
        #expect(rendered == "... [Truncated]\nmnop")
    }
}
