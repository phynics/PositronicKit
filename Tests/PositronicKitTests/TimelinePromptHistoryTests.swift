import PKPrompt
import Testing
@testable import PositronicKit

private struct TimelineSection: PromptLeaf {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let cachePolicy: CachePolicy
    let compression: CompressionStrategy
    let type: PromptSectionType
    let text: String

    init(
        id: String,
        priority: Int = 0,
        estimatedTokens: Int = 10,
        cachePolicy: CachePolicy,
        compression: CompressionStrategy = .keep,
        type: PromptSectionType = .text,
        text: String
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.cachePolicy = cachePolicy
        self.compression = compression
        self.type = type
        self.text = text
    }

    func renderContent() async -> String? {
        text
    }
}

@Suite("TimelinePromptHistory")
actor TimelinePromptHistoryTests {
    @Test("Exposes subtree diff node-path stats")
    func exposesSubtreeDiffStats() async {
        let history = TimelinePromptHistory()
        let sections = [
            TimelineSection(id: "system", cachePolicy: .stable, text: "A"),
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B"),
        ].flatMap { $0.resolve(in: PromptResolutionContext()) }

        _ = await history.record(sections: sections, renderedContent: ["system": "A", "query": "B"])
        let diff = await history.record(sections: sections, renderedContent: ["system": "A2", "query": "B"])

        #expect(diff.changedNodePaths == [sections[0].path])
        #expect(diff.stableNodePaths == [sections[1].path])
        #expect(diff.addedNodePaths.isEmpty)
        #expect(diff.removedNodePaths.isEmpty)
    }
}
