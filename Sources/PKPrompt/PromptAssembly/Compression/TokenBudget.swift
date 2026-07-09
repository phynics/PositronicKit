import Foundation
import PKShared

/// Entry point for compressing an assembled prompt's sections to fit within a token limit.
/// Drives the structured-compression pipeline (``StructuredCompressionPlanner`` +
/// ``StructuredCompressionExecutor``) so the caller doesn't have to wire it up manually.
public struct TokenBudget: Sendable {
    /// The hard upper bound on tokens available to the whole prompt (context window size,
    /// or a caller-imposed cap).
    public let maxTokens: Int
    /// Tokens to withhold from `maxTokens` for the model's own response, so compression
    /// targets `maxTokens - reserveForResponse` for the prompt itself.
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
    ) async -> [PromptSection] {
        await apply(
            to: sections.flatMap { $0.resolveSections() },
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
    ) async -> (sections: [PromptSection], report: CompressionReport?) {
        await applyWithReport(
            to: sections.flatMap { $0.resolveSections() },
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: nodeMetadata,
            planner: planner,
            executor: executor
        )
    }

    public func apply(
        to sections: [PromptSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> [PromptSection] {
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
        to sections: [PromptSection],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async -> (sections: [PromptSection], report: CompressionReport?) {
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

        // Structured compression runs only after the prompt is already known to be over budget,
        // and only when callers provide a diff hint or precomputed node metadata. In the
        // PromptAssembler code path, metadata is always supplied for budgeted prompts, so this
        // becomes the first reduction pass rather than an uncommon optional branch.
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

        // Fall back to the simpler priority-ordered allocator if the structured pass was not
        // requested or could not reduce the prompt enough.
        let indexedSections = sections.enumerated().map { (index: $0.offset, section: $0.element) }
        let sortedByPriority = indexedSections.sorted { $0.section.priority > $1.section.priority }

        let decisions = await allocateBudget(
            sortedByPriority: sortedByPriority,
            available: available,
            compressor: compressor
        )

        let reconstructed = reconstructSections(indexedSections: indexedSections, decisions: decisions)
        return (reconstructed.sections, CompressionReport(nodeReports: reconstructed.reports))
    }

    public func makeStructuredPlan(
        sections: [PromptSection],
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
        sortedByPriority: [(index: Int, section: PromptSection)],
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
        _ section: PromptSection,
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
            return .drop(fallbackReason: "no_remaining_budget")

        case .summarize:
            guard remainingBudget > 0 else {
                return .drop(fallbackReason: "no_remaining_budget")
            }
            guard let compressor else {
                return .drop(fallbackReason: "missing_compressor")
            }
            guard let content = await section.renderedContent()?.text, !content.isEmpty else {
                return .drop(fallbackReason: "missing_content")
            }
            guard let summary = try? await compressor.summarize(content), !summary.isEmpty else {
                return .drop(fallbackReason: "summary_failed_or_empty")
            }

            let summaryTokens = estimateTokenCount(summary)
            guard summaryTokens <= remainingBudget else {
                return .drop(fallbackReason: "summary_exceeds_budget")
            }

            remainingBudget -= summaryTokens
            return .replaceWithSummary(text: summary, estimatedTokens: summaryTokens)

        case .drop:
            return .drop(fallbackReason: nil)
        }
    }

    private func reconstructSections(
        indexedSections: [(index: Int, section: PromptSection)],
        decisions: [Int: SectionDecision]
    ) -> (sections: [PromptSection], reports: [CompressionNodeReport]) {
        var result: [PromptSection] = []
        var reports: [CompressionNodeReport] = []
        for (index, section) in indexedSections {
            guard let decision = decisions[index] else { continue }
            let report = compressionReport(for: section, decision: decision)
            reports.append(report)

            switch decision {
            case .keepOriginal:
                result.append(section.withCompressionOutcome(report))
            case let .constrain(limit):
                result.append(section.constrained(to: limit, compressionOutcome: report))
            case let .replaceWithSummary(text, estimatedTokens):
                result.append(section.summarized(text, estimatedTokens: estimatedTokens, compressionOutcome: report))
            case .drop:
                break
            }
        }
        return (result, reports)
    }

    private func estimateTokenCount(_ text: String) -> Int {
        TokenEstimator.estimate(text: text)
    }

    /// Computes a fallback node hash when no precomputed metadata is available.
    ///
    /// This intentionally omits `renderedContent` from the hash inputs because
    /// `PromptSection.renderedContent()` is async and `makeStructuredPlan` is synchronous.
    /// Callers that need content-aware hashing should pass precomputed `nodeMetadata` instead.
    private func defaultNodeHash(for section: PromptSection) -> UInt64 {
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
        case drop(fallbackReason: String?)
    }

    private func compressionReport(
        for section: PromptSection,
        decision: SectionDecision
    ) -> CompressionNodeReport {
        switch decision {
        case .keepOriginal:
            return CompressionNodeReport(
                nodeId: section.id,
                path: section.path,
                action: .keep,
                beforeTokens: section.estimatedTokens,
                afterTokens: section.estimatedTokens,
                cacheHit: false,
                fallbackReason: nil
            )
        case let .constrain(limit):
            let tail: Bool
            if case let .truncate(value) = section.compression {
                tail = value
            } else {
                tail = true
            }
            return CompressionNodeReport(
                nodeId: section.id,
                path: section.path,
                action: .truncate(limit: limit, tail: tail),
                beforeTokens: section.estimatedTokens,
                afterTokens: min(section.estimatedTokens, limit),
                cacheHit: false,
                fallbackReason: nil
            )
        case let .replaceWithSummary(_, estimatedTokens):
            return CompressionNodeReport(
                nodeId: section.id,
                path: section.path,
                action: .summarize(targetTokens: estimatedTokens, reason: .budgetReduction),
                beforeTokens: section.estimatedTokens,
                afterTokens: estimatedTokens,
                cacheHit: false,
                fallbackReason: nil
            )
        case let .drop(fallbackReason):
            return CompressionNodeReport(
                nodeId: section.id,
                path: section.path,
                action: .drop,
                beforeTokens: section.estimatedTokens,
                afterTokens: 0,
                cacheHit: false,
                fallbackReason: fallbackReason
            )
        }
    }
}
