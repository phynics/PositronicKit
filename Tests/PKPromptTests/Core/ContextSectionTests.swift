import Foundation
import Testing
@testable import PKPrompt

private struct MinimalPrimitiveSection: PrimitiveContextSection {
    let id = "min"
    let priority = 1
    let estimatedTokens = 100

    func renderContent() async -> String? {
        "minimal text"
    }
}

private struct TruncatablePrimitiveSection: PrimitiveContextSection {
    let id = "truncate"
    let priority = 1
    let estimatedTokens = 100
    let compression: CompressionStrategy
    let text: String

    func renderContent() async -> String? {
        text
    }
}

@Suite("ContextSection core")
struct ContextSectionTests {
    @Test("Primitive sections use default traits")
    func defaultImplementations() async {
        let section = MinimalPrimitiveSection()
        let resolved = section.resolve(in: ContextSectionResolutionContext())

        #expect(resolved.count == 1)
        #expect(resolved[0].compression == .keep)
        #expect(resolved[0].type == .text)

        let constrainedRender = await resolved[0].render(constrainedTo: 50)
        #expect(constrainedRender == "minimal text")
    }

    @Test("Resolved sections can be constrained")
    func resolvedSectionConstraint() async {
        let base = MinimalPrimitiveSection().resolve(in: ContextSectionResolutionContext())[0]
        let constrained = base.constrained(to: 50)

        #expect(constrained.id == "min")
        #expect(constrained.priority == 1)
        #expect(constrained.estimatedTokens == 50)
    }

    @Test("Truncate tail applies during constrained rendering")
    func truncateTailRendering() async {
        let resolved = TruncatablePrimitiveSection(
            compression: .truncate(tail: true),
            text: "abcdefghijklmnop"
        ).resolve(in: ContextSectionResolutionContext())[0]

        let rendered = await resolved.render(constrainedTo: 2)
        #expect(rendered == "abcdefgh\n... [Truncated]")
    }

    @Test("Truncate head applies during constrained rendering")
    func truncateHeadRendering() async {
        let resolved = TruncatablePrimitiveSection(
            compression: .truncate(tail: false),
            text: "abcdefghijklmnop"
        ).resolve(in: ContextSectionResolutionContext())[0]

        let rendered = await resolved.render(constrainedTo: 2)
        #expect(rendered == "... [Truncated]\nijklmnop")
    }
}
