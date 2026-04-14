import Testing
import PKPrompt
@testable import PositronicKit

private struct TimelineSection: ContextSection {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let cachePolicy: CachePolicy
    let strategy: CompressionStrategy
    let type: ContextSectionType
    let text: String

    init(
        id: String,
        priority: Int = 0,
        estimatedTokens: Int = 10,
        cachePolicy: CachePolicy,
        strategy: CompressionStrategy = .keep,
        type: ContextSectionType = .text,
        text: String
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.cachePolicy = cachePolicy
        self.strategy = strategy
        self.type = type
        self.text = text
    }

    func render() async -> String? {
        text
    }
}

@Suite("TimelinePromptHistory")
actor TimelinePromptHistoryTests {
    @Test("Exposes subtree diff node-path stats")
    func exposesSubtreeDiffStats() async {
        let history = TimelinePromptHistory()
        let sections: [ContextSection] = [
            TimelineSection(id: "system", cachePolicy: .stable, text: "A"),
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B"),
        ]

        _ = await history.record(sections: sections, renderedContent: [
            "system": "A",
            "query": "B",
        ])

        let diff = await history.record(sections: sections, renderedContent: [
            "system": "A2",
            "query": "B",
        ])

        #expect(diff.changedNodePaths == [["prompt", "stable", "system"]])
        #expect(diff.stableNodePaths == [["prompt", "volatile", "query"]])
        #expect(diff.addedNodePaths.isEmpty)
        #expect(diff.removedNodePaths.isEmpty)
    }
}
