import Foundation

/// Strategy for ensuring the prompt fits within a token limit
public struct TokenBudget: Sendable {
    public let maxTokens: Int
    public let reserveForResponse: Int

    public init(maxTokens: Int, reserveForResponse: Int) {
        self.maxTokens = maxTokens
        self.reserveForResponse = reserveForResponse
    }

    /// Apply the budget to a list of sections, returning a potentially modified list
    /// - Parameters:
    ///   - sections: The sections to process
    ///   - compressor: Optional compressor for .summarize strategy
    /// - Returns: A new list of sections that fits within the budget (best effort)
    public func apply(
        to sections: [ContextSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> [ContextSection] {
        let result = await applyWithReport(
            to: sections,
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: nodeMetadata,
            planner: planner,
            executor: executor
        )
        return result.sections
    }

    public func applyWithReport(
        to sections: [ContextSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> (sections: [ContextSection], report: CompressionReport?) {
        let available = maxTokens - reserveForResponse
        let currentTotal = sections.reduce(0) { $0 + $1.estimatedTokens }

        // If we fit, return as is
        if currentTotal <= available {
            return (sections, nil)
        }

        if structuredDiff != nil || !nodeMetadata.isEmpty {
            let plan = makeStructuredPlan(
                sections: sections,
                available: available,
                structuredDiff: structuredDiff,
                nodeMetadata: nodeMetadata,
                planner: planner
            )
            let structuredResult = await executor.execute(plan: plan, sections: sections, compressor: compressor)
            let structuredTotal = structuredResult.sections.reduce(0) { $0 + $1.estimatedTokens }
            if structuredTotal <= available || plan.nodeActions.contains(where: { $0.strategy == .keep }) {
                return (structuredResult.sections, structuredResult.report)
            }
        }

        let indexedSections = sections.enumerated().map { (index: $0.offset, section: $0.element) }
        let sortedByPriority = indexedSections.sorted { $0.section.priority > $1.section.priority }

        let decisions = await allocateBudget(
            sortedByPriority: sortedByPriority,
            available: available,
            compressor: compressor
        )

        return (reconstructSections(indexedSections: indexedSections, decisions: decisions), nil)
    }

    public func makeStructuredPlan(
        sections: [ContextSection],
        available: Int,
        structuredDiff: StructuredDiffHint?,
        nodeMetadata: [String: StructuredNodeMetadata],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner()
    ) -> StructuredCompressionPlan {
        let nodes = sections.map { section in
            let metadata = nodeMetadata[section.id]
            return StructuredCompressionNode(
                id: section.id,
                path: metadata?.path ?? [section.id],
                nodeHash: metadata?.nodeHash ?? defaultNodeHash(for: section),
                priority: section.priority,
                cachePolicy: section.cachePolicy,
                strategy: section.strategy,
                estimatedTokens: section.estimatedTokens
            )
        }

        return planner.plan(nodes: nodes, availableTokens: available, diff: structuredDiff)
    }

    // MARK: - Budget Allocation

    /// Allocate budget to sections sorted by priority, returning a decision per original index
    private func allocateBudget(
        sortedByPriority: [(index: Int, section: ContextSection)],
        available: Int,
        compressor: SectionCompressor?
    ) async -> [Int: SectionDecision] {
        var decisions: [Int: SectionDecision] = [:]
        var remainingBudget = available

        for (index, section) in sortedByPriority {
            let size = section.estimatedTokens

            if size <= remainingBudget {
                decisions[index] = .keepOriginal
                remainingBudget -= size
            } else {
                decisions[index] = await decideOverBudgetSection(
                    section,
                    remainingBudget: &remainingBudget,
                    compressor: compressor
                )
            }
        }

        return decisions
    }

    /// Decide what to do with a section that does not fully fit in the remaining budget
    private func decideOverBudgetSection(
        _ section: ContextSection,
        remainingBudget: inout Int,
        compressor: SectionCompressor?
    ) async -> SectionDecision {
        switch section.strategy {
        case .keep:
            // Must keep — go into debt if needed
            remainingBudget -= section.estimatedTokens
            return .keepOriginal

        case .truncate:
            if remainingBudget > 0 {
                let limit = remainingBudget
                remainingBudget = 0
                return .constrain(limit: limit)
            }
            return .drop

        case .summarize:
            guard
                remainingBudget > 0,
                let compressor,
                let content = await section.render(),
                !content.isEmpty,
                let summary = try? await compressor.summarize(content),
                !summary.isEmpty
            else {
                return .drop
            }

            let summaryTokens = estimateTokenCount(summary)
            guard summaryTokens <= remainingBudget else {
                return .drop
            }

            remainingBudget -= summaryTokens
            return .replaceWithSummary(text: summary, estimatedTokens: summaryTokens)

        case .drop:
            return .drop
        }
    }

    /// Reconstruct sections in original order based on allocation decisions
    private func reconstructSections(
        indexedSections: [(index: Int, section: ContextSection)],
        decisions: [Int: SectionDecision]
    ) -> [ContextSection] {
        var result: [ContextSection] = []
        for (index, section) in indexedSections {
            guard let decision = decisions[index] else { continue }

            switch decision {
            case .keepOriginal:
                result.append(section)
            case let .constrain(limit):
                result.append(section.constrained(to: limit))
            case let .replaceWithSummary(text, estimatedTokens):
                result.append(SummarizedSection(base: section, summary: text, estimatedTokens: estimatedTokens))
            case .drop:
                break
            }
        }
        return result
    }

    private func estimateTokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private func defaultNodeHash(for section: ContextSection) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(section.id)
        hasher.combine(section.estimatedTokens)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private enum SectionDecision {
        case keepOriginal
        case constrain(limit: Int)
        case replaceWithSummary(text: String, estimatedTokens: Int)
        case drop
    }
}

struct SummarizedSection: ContextSection {
    let base: ContextSection
    let summary: String
    let estimatedTokens: Int

    var id: String { base.id }
    var priority: Int { base.priority }
    var strategy: CompressionStrategy { .keep }
    var type: ContextSectionType { .text }
    var cachePolicy: CachePolicy { base.cachePolicy }

    func render() async -> String? {
        summary
    }
}
