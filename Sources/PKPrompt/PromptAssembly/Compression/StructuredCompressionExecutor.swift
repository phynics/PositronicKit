import Foundation

/// Executes a structured compression plan against a set of prompt sections.
///
/// This actor applies planned per-node actions (keep, truncate, summarize, drop)
/// and produces both the transformed sections and a detailed `CompressionReport`
/// for auditing and analytics.
///
/// In the `PromptAssembler` token-budgeted path, this executor runs as the first reduction pass
/// only after the assembled prompt is found to be over budget, before the simpler priority-based
/// fallback allocator.
public actor StructuredCompressionExecutor {

    /// Create an executor.
    public init() {}

    /// Apply a structured compression plan to the provided sections.
    ///
    /// The executor validates inputs, orders node actions to process deeper paths first,
    /// applies each action, reconstructs the resulting section list (omitting dropped nodes),
    /// and returns a `StructuredExecutionResult` containing both the transformed sections
    /// and a `CompressionReport` with one `CompressionNodeReport` per planned or executed action.
    ///
    /// - Parameters:
    ///   - plan: The planned node actions and related metadata.
    ///   - sections: The source sections to transform.
    ///   - compressor: Optional summarization engine used for `.summarize` actions.
    /// - Returns: The transformed sections and a detailed compression report.
    public func execute(
        plan: StructuredCompressionPlan,
        sections: [PromptSection],
        compressor: SectionCompressor?
    ) async -> StructuredExecutionResult {
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        precondition(
            duplicateIDs.isEmpty,
            "Duplicate context section ids in StructuredCompressionExecutor.execute sections: \(duplicateIDs.joined(separator: ", "))"
        )
        precondition(
            Set(plan.nodeActions.map(\.nodeId)).count == plan.nodeActions.count,
            "Duplicate planned node ids are not supported"
        )
        let actionById = Dictionary(uniqueKeysWithValues: plan.nodeActions.map { ($0.nodeId, $0) })
        let sectionsById = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })

        // Process deeper nodes first so child transformations occur before parents.
        // Break ties lexicographically for deterministic ordering.
        let sortedPlanActions = plan.nodeActions.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            return lhs.path.lexicographicallyPrecedes(rhs.path)
        }

        var reportsById: [String: CompressionNodeReport] = [:]
        var transformedSectionsById: [String: PromptSection] = [:]

        for planned in sortedPlanActions {
            guard let section = sectionsById[planned.nodeId] else { continue }

            let output = await applyAction(planned, section: section, compressor: compressor)
            transformedSectionsById[planned.nodeId] = output.section
            reportsById[planned.nodeId] = output.report
        }

        // Reconstruct the final section list in original order, omitting any that were dropped.
        var resultingSections: [PromptSection] = []
        var reports: [CompressionNodeReport] = []

        for section in sections {
            if let transformed = transformedSectionsById[section.id] {
                if let report = reportsById[section.id], case .drop = report.action {
                    // dropped: skip adding to resultingSections
                } else {
                    resultingSections.append(transformed)
                }
            } else {
                resultingSections.append(section)
            }

            if let report = reportsById[section.id] {
                reports.append(report)
            } else if let planned = actionById[section.id] {
                // Synthesize a no-op report for planned-but-unreported nodes
                reports.append(makeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: planned.action,
                    before: planned.estimatedTokens,
                    after: planned.estimatedTokens
                ))
            }
        }

        return StructuredExecutionResult(
            sections: resultingSections,
            report: CompressionReport(nodeReports: reports)
        )
    }

    /// Apply a single planned action to a section and produce a node-level report.
    ///
    /// - Parameters:
    ///   - planned: The planned action and associated metadata for the node.
    ///   - section: The source section to transform.
    ///   - compressor: Optional summarization engine used for `.summarize`.
    /// - Returns: The transformed section (or dropped) and the corresponding report.
    private func applyAction(
        _ planned: PlannedNodeAction,
        section: PromptSection,
        compressor: SectionCompressor?
    ) async -> (section: PromptSection, report: CompressionNodeReport) {
        switch planned.action {
        case .keep:
            let report = makeReport(
                nodeId: planned.nodeId,
                path: planned.path,
                action: planned.action,
                before: planned.estimatedTokens,
                after: planned.estimatedTokens
            )
            return (
                section.withCompressionOutcome(report),
                report
            )

        case let .truncate(limit, _):
            let limited = max(0, limit)
            let report = makeReport(
                nodeId: planned.nodeId,
                path: planned.path,
                action: planned.action,
                before: planned.estimatedTokens,
                after: limited
            )
            let constrained = section.constrained(to: limited, compressionOutcome: report)
            return (
                constrained,
                report
            )

        case let .summarize(targetTokens, reason):
            // Summarize requires a compressor and non-empty text content; otherwise we drop with a fallback reason.
            guard let compressor,
                  let content = await section.renderedContent()?.text,
                  !content.isEmpty
            else {
                let report = makeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: .drop,
                    before: planned.estimatedTokens,
                    after: 0,
                    fallback: "missing_compressor_or_content"
                )
                let dropped = section.dropped(compressionOutcome: report)
                return (
                    dropped,
                    report
                )
            }

            // Cache removed; always generate summary fresh.
            do {
                let request = SummaryRequest(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    text: content,
                    targetTokens: targetTokens,
                    reason: reason
                )
                let summary = try await compressor.summarize(request: request)
                guard !summary.isEmpty else {
                    let report = makeReport(
                        nodeId: planned.nodeId,
                        path: planned.path,
                        action: .drop,
                        before: planned.estimatedTokens,
                        after: 0,
                        fallback: "empty_summary"
                    )
                    let dropped = section.dropped(compressionOutcome: report)
                    return (
                        dropped,
                        report
                    )
                }

                let summaryTokens = max(1, summary.count / 4)
                let report = makeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: planned.action,
                    before: planned.estimatedTokens,
                    after: summaryTokens
                )
                return (
                    section.summarized(summary, estimatedTokens: summaryTokens, compressionOutcome: report),
                    report
                )
            } catch {
                let report = makeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: .drop,
                    before: planned.estimatedTokens,
                    after: 0,
                    fallback: "summary_failed"
                )
                let dropped = section.dropped(compressionOutcome: report)
                return (
                    dropped,
                    report
                )
            }

        case .drop:
            let report = makeReport(
                nodeId: planned.nodeId,
                path: planned.path,
                action: .drop,
                before: planned.estimatedTokens,
                after: 0
            )
            let dropped = section.dropped(compressionOutcome: report)
            return (
                dropped,
                report
            )
        }
    }

    /// Build a `CompressionNodeReport` with common defaults.
    private func makeReport(
        nodeId: String,
        path: [String],
        action: CompressionAction,
        before: Int,
        after: Int,
        cacheHit: Bool = false,
        fallback: String? = nil
    ) -> CompressionNodeReport {
        CompressionNodeReport(
            nodeId: nodeId,
            path: path,
            action: action,
            beforeTokens: before,
            afterTokens: after,
            cacheHit: cacheHit,
            fallbackReason: fallback
        )
    }
}
