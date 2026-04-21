import Foundation
import Testing
@testable import PKPrompt

private struct MinimalPromptLeaf: PromptLeaf {
    let id = "min"
    let priority = 1
    let estimatedTokens = 100

    func renderContent() async -> String? {
        "minimal text"
    }
}

private struct TruncatablePromptLeaf: PromptLeaf {
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
    @Test("Prompt leaves use default traits")
    func defaultImplementations() async {
        let section = MinimalPromptLeaf()
        let resolved = section.resolve(in: PromptResolutionContext())

        #expect(resolved.count == 1)
        #expect(resolved[0].compression == .keep)
        #expect(resolved[0].type == .text)

        let constrainedRender = await resolved[0].renderText(constrainedTo: 50)
        #expect(constrainedRender == "minimal text")
    }

    @Test("Concrete sections can be constrained")
    func concreteSectionConstraint() async {
        let base = MinimalPromptLeaf().resolve(in: PromptResolutionContext())[0]
        let constrained = base.constrained(to: 50)

        #expect(constrained.id == "min")
        #expect(constrained.priority == 1)
        #expect(constrained.estimatedTokens == 50)
    }

    @Test("Truncate tail applies during constrained rendering")
    func truncateTailRendering() async {
        let resolved = TruncatablePromptLeaf(
            compression: .truncate(tail: true),
            text: "abcdefghijklmnop"
        ).resolve(in: PromptResolutionContext())[0]

        let rendered = await resolved.renderText(constrainedTo: 2)
        #expect(rendered == "abcdefgh\n... [Truncated]")
    }

    @Test("Truncate head applies during constrained rendering")
    func truncateHeadRendering() async {
        let resolved = TruncatablePromptLeaf(
            compression: .truncate(tail: false),
            text: "abcdefghijklmnop"
        ).resolve(in: PromptResolutionContext())[0]

        let rendered = await resolved.renderText(constrainedTo: 2)
        #expect(rendered == "... [Truncated]\nijklmnop")
    }
}
