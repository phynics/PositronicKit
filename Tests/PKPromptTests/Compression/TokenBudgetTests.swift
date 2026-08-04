import Foundation
import Testing
@testable import PKPrompt

private struct MockPrimitiveSection: PromptPrimitive {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let compression: CompressionStrategy
    let type: PromptSectionType
    let renderedContent: String

    init(
        id: String,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy = .keep,
        type: PromptSectionType = .text,
        renderedContent: String = "content"
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.compression = compression
        self.type = type
        self.renderedContent = renderedContent
    }

    func renderContent() async -> String? {
        renderedContent
    }
}

private struct MockCompressor: SectionCompressor {
    let summarizedText: String

    func summarize(_: String) async throws -> String {
        summarizedText
    }

    func summarize(request: SummaryRequest) async throws -> String {
        summarizedText
    }
}

private enum SummarizerError: Error, Equatable, Sendable {
    case unavailable
}

private struct FailingCompressor: SectionCompressor {
    func summarize(_: String) async throws -> String {
        throw SummarizerError.unavailable
    }
}

private func resolve(_ sections: [MockPrimitiveSection]) -> [PromptSection] {
    sections.map { $0.makeSection() }
}

@Suite("TokenBudget")
struct TokenBudgetTests {
    @Test("Under-budget sections remain unchanged")
    func applyUnderBudget() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 200)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 1, estimatedTokens: 400),
            MockPrimitiveSection(id: "s2", priority: 2, estimatedTokens: 300),
        ])

        let result = try await budget.result(forResolvedSections: sections).sections
        #expect(result.map(\.id) == ["s1", "s2"])
    }

    @Test("High-priority drop sections win budget allocation")
    func applyOverBudgetPrioritizesHighPriority() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "low", priority: 1, estimatedTokens: 800, compression: .drop),
            MockPrimitiveSection(id: "high", priority: 2, estimatedTokens: 800, compression: .drop),
        ])

        let result = try await budget.result(forResolvedSections: sections).sections
        #expect(result.count == 1)
        #expect(result[0].id == "high")
    }

    @Test("Keep sections fail when they cannot fit the budget")
    func applyKeepExceedsBudget() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "keep1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "keep2", priority: 1, estimatedTokens: 800, compression: .keep),
        ])

        await #expect(throws: PromptCompressionError.mandatorySectionOverflow(
            sectionID: "keep2", estimatedTokens: 800, availableTokens: 200
        )) {
            try await budget.result(forResolvedSections: sections)
        }
    }

    @Test("A mandatory section that is larger than the budget fails with a typed overflow")
    func mandatorySectionOverflowIsTyped() async throws {
        let budget = TokenBudget(maxTokens: 100)
        let sections = resolve([
            MockPrimitiveSection(id: "mandatory", priority: 1, estimatedTokens: 101, compression: .keep),
        ])

        await #expect(throws: PromptCompressionError.mandatorySectionOverflow(
            sectionID: "mandatory", estimatedTokens: 101, availableTokens: 100
        )) {
            try await budget.result(forResolvedSections: sections)
        }
    }

    @Test("Successful budgeting reports a result within the available budget")
    func budgetResultNeverExceedsAvailable() async throws {
        let budget = TokenBudget(maxTokens: 100)
        let sections = resolve([
            MockPrimitiveSection(id: "keep", priority: 2, estimatedTokens: 80, compression: .keep),
            MockPrimitiveSection(id: "drop", priority: 1, estimatedTokens: 80, compression: .drop),
        ])

        let result = try await budget.result(forResolvedSections: sections)
        #expect(result.estimatedTokens <= result.availableTokens)
    }

    @Test("Summarizer failures preserve the original error")
    func summarizerFailureIsNotConvertedToDrop() async throws {
        let budget = TokenBudget(maxTokens: 100)
        let sections = resolve([
            MockPrimitiveSection(id: "keep", priority: 2, estimatedTokens: 80, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 80, compression: .summarize),
        ])

        await #expect(throws: SummarizerError.unavailable) {
            try await budget.result(forResolvedSections: sections, compressor: FailingCompressor())
        }
    }

    @Test("Truncate sections are constrained to remaining budget")
    func applyTruncateSqueezesToRemaining() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "keep", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "truncate", priority: 1, estimatedTokens: 500, compression: .truncate(keeping: .head)),
        ])

        let result = try await budget.result(forResolvedSections: sections).sections
        #expect(result.count == 2)
        #expect(result[1].id == "truncate")
        #expect(result[1].estimatedTokens == 200)

        let rendered = await result[1].renderedContent()?.text
        #expect(rendered?.count == 7)
    }

    @Test("Drop and empty-budget truncate sections are removed")
    func applyDropWithoutBudget() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 1000, compression: .keep),
            MockPrimitiveSection(id: "drop", priority: 1, estimatedTokens: 500, compression: .drop),
            MockPrimitiveSection(id: "truncate_dropped", priority: 0, estimatedTokens: 500, compression: .truncate(keeping: .head)),
        ])

        let result = try await budget.result(forResolvedSections: sections).sections
        #expect(result.count == 1)
        #expect(result[0].id == "s1")
    }

    @Test("Summarize without compressor falls back to drop")
    func applySummarizeFallsBackToDrop() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 500, compression: .summarize),
        ])

        let result = try await budget.result(forResolvedSections: sections).sections
        #expect(result.count == 1)
        #expect(result[0].id == "s1")
    }

    @Test("Summarize uses compressor when available")
    func applySummarizeUsesCompressorWhenAvailable() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 500, compression: .summarize, renderedContent: "A very long body"),
        ])

        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: "short summary")
        ).sections

        #expect(result.count == 2)
        #expect(result[1].id == "summarize")
        #expect(result[1].estimatedTokens <= 200)
        #expect(await result[1].renderedContent()?.text == "short summary")
    }

    @Test("Summaries are re-estimated with shared token estimator")
    func applySummarizeReestimatesSummaryTokens() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 500, compression: .summarize, renderedContent: "A very long body"),
        ])

        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: "你好世界")
        ).sections

        #expect(result.count == 2)
        #expect(result[1].estimatedTokens == 4)
    }

    @Test("Fallback compression reports summarized sections and preserves requested strategy")
    func fallbackCompressionReportsSummaries() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 500, compression: .summarize, renderedContent: "A very long body"),
        ])

        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: "short summary")
        )

        #expect(result.report != nil)
        #expect(result.sections.count == 2)
        #expect(result.sections[1].compression == .summarize)
        #expect(result.sections[1].compressionOutcome?.action == .summarize(targetTokens: result.sections[1].estimatedTokens, reason: .budgetReduction))
        #expect(result.report?.nodeReports.contains(where: {
            $0.nodeID == "summarize" && $0.action == .summarize(targetTokens: result.sections[1].estimatedTokens, reason: .budgetReduction)
        }) == true)
    }

    @Test("Summarize drops when summary still does not fit")
    func applySummarizeDropsWhenSummaryStillTooLarge() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "s1", priority: 2, estimatedTokens: 800, compression: .keep),
            MockPrimitiveSection(id: "summarize", priority: 1, estimatedTokens: 500, compression: .summarize, renderedContent: "A very long body"),
        ])

        let tooLongSummary = String(repeating: "你", count: 1000)
        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: tooLongSummary)
        ).sections

        #expect(result.count == 1)
        #expect(result[0].id == "s1")
    }

    @Test("Structured compression respects diff priority")
    func applyStructuredCompressionRespectsDiffPriority() async throws {
        let budget = TokenBudget(maxTokens: 500, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "stable", priority: 10, estimatedTokens: 300, compression: .summarize, renderedContent: "stable body"),
            MockPrimitiveSection(id: "changed", priority: 1, estimatedTokens: 300, compression: .summarize, renderedContent: "changed body"),
        ])

        let diff = StructuredDiffHint(
            changedNodePaths: [sections[1].path],
            stableNodePaths: [sections[0].path]
        )
        let metadata = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, StructuredNodeMetadata(path: $0.path, nodeHash: 1)) })

        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: "short"),
            structuredDiff: diff,
            nodeMetadata: metadata
        ).sections

        #expect(result.count == 1)
        #expect(result[0].id == "changed")
    }

    @Test("Structured compression rejects an impossible keep section")
    func applyStructuredCompressionNeverSummarizesKeepSections() async throws {
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "must_keep", priority: 10, estimatedTokens: 200, compression: .keep, renderedContent: "must keep"),
            MockPrimitiveSection(id: "other", priority: 1, estimatedTokens: 200, compression: .summarize, renderedContent: "compress me"),
        ])

        await #expect(throws: PromptCompressionError.mandatorySectionOverflow(
            sectionID: "must_keep", estimatedTokens: 200, availableTokens: 100
        )) {
            try await budget.result(forResolvedSections: sections, compressor: MockCompressor(summarizedText: "tiny"))
        }
    }

    @Test("Structured plan falls back if execution remains over budget")
    func applyStructuredFallsBackWhenStructuredResultStillOverBudget() async throws {
        let budget = TokenBudget(maxTokens: 1000, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "keep_small", priority: 100, estimatedTokens: 100, compression: .keep, renderedContent: "keep"),
            MockPrimitiveSection(id: "summarize_large", priority: 1, estimatedTokens: 950, compression: .summarize, renderedContent: "very long body"),
        ])

        let metadata = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, StructuredNodeMetadata(path: $0.path, nodeHash: 1)) })
        let result = try await budget.result(
            for: sections,
            compressor: MockCompressor(summarizedText: String(repeating: "你", count: 1000)),
            nodeMetadata: metadata
        ).sections

        #expect(result.count == 1)
        #expect(result[0].id == "keep_small")
    }

    @Test("Duplicate section IDs throw instead of terminating the process")
    func duplicateSectionIDsAreRecoverable() async throws {
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)
        let sections = resolve([
            MockPrimitiveSection(id: "duplicate", priority: 1, estimatedTokens: 10),
            MockPrimitiveSection(id: "duplicate", priority: 1, estimatedTokens: 10),
        ])

        do {
            _ = try await budget.result(forResolvedSections: sections)
            Issue.record("Duplicate section IDs were accepted")
        } catch let error as PromptCompressionError {
            #expect(error == .duplicateSectionIDs(["duplicate"]))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Prompt ID and budget boundary cases remain typed and non-crashing")
    func promptInputBoundariesAreRecoverable() async throws {
        for value in [-10, -1, 0, 1, 10, 10_000] {
            if value <= 0 {
                #expect(throws: TokenBudgetError.nonPositiveContextWindow(value)) {
                    try TokenBudget(contextWindow: value, outputReserve: 0)
                }
            } else {
                _ = try TokenBudget(contextWindow: value, outputReserve: min(value - 1, 1))
            }
        }

        for id in ["", "duplicate", "duplicate", String(repeating: "x", count: 128)] {
            let sections = resolve([
                MockPrimitiveSection(id: id, priority: 1, estimatedTokens: 10),
                MockPrimitiveSection(id: id, priority: 1, estimatedTokens: 10),
            ])
            do {
                _ = try await TokenBudget(maxTokens: 100).result(forResolvedSections: sections)
                Issue.record("Duplicate section ID was accepted")
            } catch let error as PromptCompressionError {
                #expect(error == .duplicateSectionIDs([id]))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}
