import Foundation
import PKShared

public struct TokenBudget: Sendable {
    public let maxTokens: Int
    public let reserveForResponse: Int

    public init(maxTokens: Int, reserveForResponse: Int) {
        self.maxTokens = maxTokens
        self.reserveForResponse = reserveForResponse
    }

    public func apply(
        to sections: [any Prompt],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> [ConcretePromptSection] {
        await apply(
            to: sections.flatMap { $0.resolveSections(in: PromptResolutionContext()) },
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: nodeMetadata,
            planner: planner,
            executor: executor
        )
    }

    public func applyWithReport(
        to sections: [any Prompt],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> (sections: [ConcretePromptSection], report: CompressionReport?) {
        await applyWithReport(
            to: sections.flatMap { $0.resolveSections(in: PromptResolutionContext()) },
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: nodeMetadata,
            planner: planner,
            executor: executor
        )
    }

    public func apply(
        to sections: [ConcretePromptSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> [ConcretePromptSection] {
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
        to sections: [ConcretePromptSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> (sections: [ConcretePromptSection], report: CompressionReport?) {
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        precondition(
            duplicateIDs.isEmpty,
            "Duplicate context section ids in TokenBudget.applyWithReport: \(duplicateIDs.joined(separator: ", "))"
        )
        let available = maxTokens - reserveForResponse
        let currentTotal = sections.reduce(0) { $0 + $1.estimatedTokens }

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
            if structuredTotal <= available {
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
        sections: [ConcretePromptSection],
        available: Int,
        structuredDiff: StructuredDiffHint?,
        nodeMetadata: [String: StructuredNodeMetadata],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner()
    ) -> StructuredCompressionPlan {
        let nodes = sections.map { section in
            let metadata = nodeMetadata[section.id]
            return StructuredCompressionNode(
                id: section.id,
                path: metadata?.path ?? section.path,
                nodeHash: metadata?.nodeHash ?? defaultNodeHash(for: section),
                priority: section.priority,
                cachePolicy: section.cachePolicy,
                strategy: section.compression,
                estimatedTokens: section.estimatedTokens
            )
        }

        return planner.plan(nodes: nodes, availableTokens: available, diff: structuredDiff)
    }

    private func allocateBudget(
        sortedByPriority: [(index: Int, section: ConcretePromptSection)],
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

    private func decideOverBudgetSection(
        _ section: ConcretePromptSection,
        remainingBudget: inout Int,
        compressor: SectionCompressor?
    ) async -> SectionDecision {
        switch section.compression {
        case .keep:
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
                let content = await section.renderText(),
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

    private func reconstructSections(
        indexedSections: [(index: Int, section: ConcretePromptSection)],
        decisions: [Int: SectionDecision]
    ) -> [ConcretePromptSection] {
        var result: [ConcretePromptSection] = []
        for (index, section) in indexedSections {
            guard let decision = decisions[index] else { continue }

            switch decision {
            case .keepOriginal:
                result.append(section)
            case let .constrain(limit):
                result.append(section.constrained(to: limit))
            case let .replaceWithSummary(text, estimatedTokens):
                result.append(section.summarized(text, estimatedTokens: estimatedTokens))
            case .drop:
                break
            }
        }
        return result
    }

    private func estimateTokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private func defaultNodeHash(for section: ConcretePromptSection) -> UInt64 {
        StableHash.hash(components: [
            section.id,
            String(section.estimatedTokens),
            String(section.priority),
            String(describing: section.cachePolicy),
        ])
    }

    private enum SectionDecision {
        case keepOriginal
        case constrain(limit: Int)
        case replaceWithSummary(text: String, estimatedTokens: Int)
        case drop
    }
}
