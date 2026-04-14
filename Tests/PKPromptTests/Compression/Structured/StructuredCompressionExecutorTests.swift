import Testing
import Foundation
@testable import PKPrompt

private struct RecordingCompressor: SectionCompressor {
    let result: String
    let onRequest: @Sendable (SummaryRequest) -> Void

    init(result: String, onRequest: @escaping @Sendable (SummaryRequest) -> Void = { _ in }) {
        self.result = result
        self.onRequest = onRequest
    }

    func summarize(_ text: String) async throws -> String {
        result
    }

    func summarize(request: SummaryRequest) async throws -> String {
        onRequest(request)
        return result
    }
}

@Suite("StructuredCompressionExecutor")
struct StructuredCompressionExecutorTests {
    @Test("Executes plan and preserves section ordering")
    func executesPlanInOrder() async {
        let sections: [ContextSection] = [
            MockContextSection(id: "s1", priority: 1, estimatedTokens: 300, strategy: .summarize, renderedContent: "A long body"),
            MockContextSection(id: "s2", priority: 1, estimatedTokens: 100, strategy: .keep, renderedContent: "Keep me"),
        ]
        let plan = StructuredCompressionPlan(
            availableTokens: 150,
            totalEstimatedTokens: 400,
            nodeActions: [
                .init(nodeId: "s1", path: ["prompt", "volatile", "s1"], nodeHash: 11, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
                .init(nodeId: "s2", path: ["prompt", "stable", "s2"], nodeHash: 22, strategy: .keep, estimatedTokens: 100, action: .keep),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = await executor.execute(plan: plan, sections: sections, compressor: RecordingCompressor(result: "summary"))

        #expect(result.sections.map(\.id) == ["s1", "s2"])
        let rendered = await result.sections[0].render()
        #expect(rendered == "summary")
    }

    @Test("Uses summary cache keyed by nodeHash and target tokens")
    func usesSummaryCache() async {
        let sections: [ContextSection] = [
            MockContextSection(id: "s1", priority: 1, estimatedTokens: 300, strategy: .summarize, renderedContent: "A long body"),
        ]

        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s1", path: ["prompt", "volatile", "s1"], nodeHash: 100, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
            ]
        )

        let counter = LockedCounter()
        let compressor = RecordingCompressor(result: "cached") { _ in
            counter.increment()
        }
        let executor = StructuredCompressionExecutor()

        _ = await executor.execute(plan: plan, sections: sections, compressor: compressor)
        _ = await executor.execute(plan: plan, sections: sections, compressor: compressor)

        #expect(counter.value == 1)
    }

    @Test("Evicts oldest summaries when cache reaches capacity")
    func evictsOldestSummaries() async {
        let section1: [ContextSection] = [
            MockContextSection(id: "s1", priority: 1, estimatedTokens: 300, strategy: .summarize, renderedContent: "Body 1"),
        ]
        let section2: [ContextSection] = [
            MockContextSection(id: "s2", priority: 1, estimatedTokens: 300, strategy: .summarize, renderedContent: "Body 2"),
        ]

        let plan1 = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s1", path: ["prompt", "volatile", "s1"], nodeHash: 100, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
            ]
        )
        let plan2 = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s2", path: ["prompt", "volatile", "s2"], nodeHash: 200, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
            ]
        )

        let counter = LockedCounter()
        let compressor = RecordingCompressor(result: "summary") { _ in
            counter.increment()
        }
        let executor = StructuredCompressionExecutor(maxSummaryCacheEntries: 1)

        _ = await executor.execute(plan: plan1, sections: section1, compressor: compressor)
        _ = await executor.execute(plan: plan2, sections: section2, compressor: compressor)
        _ = await executor.execute(plan: plan1, sections: section1, compressor: compressor)

        #expect(counter.value == 3)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
