import Foundation
import Testing
@testable import PKPrompt

private struct ExecutorMockSection: PromptPrimitive {
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

private func resolveExecutorSections(_ sections: [ExecutorMockSection]) -> [PromptSection] {
    sections.map { $0.makeSection() }
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
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 11, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
                .init(nodeID: "s2", path: sections[1].path, nodeHash: 22, strategy: .keep, estimatedTokens: 100, action: .keep),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = try! await executor.execute(plan: plan, sections: sections, compressor: RecordingCompressor(result: "summary"))

        #expect(result.sections.map(\.id) == ["s1", "s2"])
        #expect(result.sections[0].compression == .summarize)
        #expect(result.sections[0].compressionOutcome?.action == .summarize(targetTokens: 50, reason: .budgetReduction))
        #expect(await result.sections[0].renderedContent()?.text == "summary")
    }

    @Test("Repeated executions summarize each time without a summary cache")
    func repeatedExecutionsSummarizeEachTime() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 100, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 20, reason: .budgetReduction)),
            ]
        )

        let counter = LockedCounter()
        let compressor = RecordingCompressor(result: "cached") { _ in
            counter.increment()
        }
        let executor = StructuredCompressionExecutor()

        _ = try! await executor.execute(plan: plan, sections: sections, compressor: compressor)
        _ = try! await executor.execute(plan: plan, sections: sections, compressor: compressor)

        #expect(counter.value == 2)
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

// MARK: - Additional executor coverage

private struct FailingCompressor: SectionCompressor {
    func summarize(_: String) async throws -> String {
        throw NSError(domain: "test", code: 1)
    }
    func summarize(request _: SummaryRequest) async throws -> String {
        throw NSError(domain: "test", code: 1)
    }
}

private struct EmptySummaryCompressor: SectionCompressor {
    func summarize(_: String) async throws -> String { "" }
    func summarize(request _: SummaryRequest) async throws -> String { "" }
}

extension StructuredCompressionExecutorTests {
    @Test("Truncate action constrains the section to the token limit")
    func truncateAction() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .truncate(keeping: .tail), renderedContent: "A long body of text"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 1, strategy: .truncate(keeping: .tail), estimatedTokens: 300, action: .truncate(limit: 50, keeping: .tail)),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = try! await executor.execute(plan: plan, sections: sections, compressor: nil)

        #expect(result.sections.count == 1)
        #expect(result.sections[0].compressionOutcome?.action == .truncate(limit: 50, keeping: .tail))
        #expect(result.sections[0].compressionOutcome?.afterTokens == 50)
    }

    @Test("Drop action removes the section from the result")
    func dropAction() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .drop, renderedContent: "Drop me"),
            ExecutorMockSection(id: "s2", priority: 1, estimatedTokens: 100, compression: .keep, renderedContent: "Keep me"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 100,
            totalEstimatedTokens: 400,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 1, strategy: .drop, estimatedTokens: 300, action: .drop),
                .init(nodeID: "s2", path: sections[1].path, nodeHash: 2, strategy: .keep, estimatedTokens: 100, action: .keep),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = try! await executor.execute(plan: plan, sections: sections, compressor: nil)

        // s1 is dropped, only s2 remains.
        #expect(result.sections.count == 1)
        #expect(result.sections[0].id == "s2")
        // The report for s1 should still be present.
        #expect(result.report.nodeReports.count == 2)
        #expect(result.report.nodeReports[0].action == .drop)
    }

    @Test("Summarize without a compressor falls back to drop")
    func summarizeWithoutCompressorFallsBackToDrop() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 1, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = try! await executor.execute(plan: plan, sections: sections, compressor: nil)

        // Should drop with a fallback reason.
        #expect(result.sections.count == 0)
        #expect(result.report.nodeReports.first?.action == .drop)
        #expect(result.report.nodeReports.first?.fallbackReason == "missing_compressor_or_content")
    }

    @Test("Summarize with an empty summary falls back to drop")
    func summarizeWithEmptySummaryFallsBackToDrop() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 1, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
            ]
        )

        let executor = StructuredCompressionExecutor()
        let result = try! await executor.execute(plan: plan, sections: sections, compressor: EmptySummaryCompressor())

        #expect(result.sections.count == 0)
        #expect(result.report.nodeReports.first?.action == .drop)
        #expect(result.report.nodeReports.first?.fallbackReason == "empty_summary")
    }

    @Test("Summarize with a failing compressor preserves the original error")
    func summarizeWithFailingCompressorFallsBackToDrop() async {
        let sections = resolveExecutorSections([
            ExecutorMockSection(id: "s1", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "A long body"),
        ])
        let plan = StructuredCompressionPlan(
            availableTokens: 50,
            totalEstimatedTokens: 300,
            nodeActions: [
                .init(nodeID: "s1", path: sections[0].path, nodeHash: 1, strategy: .summarize, estimatedTokens: 300, action: .summarize(targetTokens: 50, reason: .budgetReduction)),
            ]
        )

        let executor = StructuredCompressionExecutor()
        do {
            _ = try await executor.execute(plan: plan, sections: sections, compressor: FailingCompressor())
            Issue.record("Expected the summarizer error to propagate")
        } catch let error as NSError {
            #expect(error.domain == "test")
            #expect(error.code == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
