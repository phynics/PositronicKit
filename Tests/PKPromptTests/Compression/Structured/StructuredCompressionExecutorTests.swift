import Foundation
import Testing
@testable import PKPrompt

private struct ExecutorMockSection: PromptLeaf {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let compression: CompressionStrategy
    let renderedContent: String

    func renderContent() async -> String? {
        renderedContent
    }
}

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

private func resolveExecutorSections(_ sections: [ExecutorMockSection]) -> [ConcretePromptSection] {
    sections.flatMap { $0.resolveSections(in: PromptResolutionContext()) }
}

@Suite("StructuredCompressionExecutor")
struct StructuredCompressionExecutorTests {
    @Test("Executes plan and preserves section ordering")
    func executesPlanInOrder() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
            ExecutorMockSection(id: "s2", priority: 1, estimatedTokens: 100, compression: .keep, renderedContent: "Keep me"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 150,
            totalEstimatedTokens: 400,
            nodeActions: [
                .init(nodeId: "s1", path: sections[0].path, nodeHash: 11, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
                .init(nodeId: "s2", path: sections[1].path, nodeHash: 22, strategy: .keep, estimatedTokens: 100, action: .keep),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = await executor.execute(plan: plan, sections: sections, compressor: RecordingCompressor(result: "summary"))

        #expect(result.sections.map(\.id) == ["s1", "s2"])
        #expect(await result.sections[0].renderText() == "summary")
    }

    @Test("Uses summary cache keyed by nodeHash and target tokens")
    func usesSummaryCache() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s1", path: sections[0].path, nodeHash: 100, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
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
        let section1 = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "Body 1"),
        ])
        let section2 = resolveExecutorSections([
            ExecutorMockSection(id: "s2", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "Body 2"),
        ])

        let plan1 = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s1", path: section1[0].path, nodeHash: 100, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
            ]
        )
        let plan2 = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeId: "s2", path: section2[0].path, nodeHash: 200, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
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
