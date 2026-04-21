import Foundation

public actor StructuredCompressionExecutor {
    private struct SummaryCacheKey: Hashable, Sendable {
        let nodeHash: UInt64
        let targetTokens: Int
    }

    private var summaryCache: [SummaryCacheKey: String] = [:]
    private var summaryCacheInsertionOrder: [SummaryCacheKey] = []
    private let maxSummaryCacheEntries: Int

    public init(maxSummaryCacheEntries: Int = 256) {
        self.maxSummaryCacheEntries = max(1, maxSummaryCacheEntries)
    }

    public func execute(
        plan: StructuredCompressionPlan,
        sections: [ConcretePromptSection],
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

        let sortedPlanActions = plan.nodeActions.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            return lhs.path.lexicographicallyPrecedes(rhs.path)
        }

        var reportsById: [String: CompressionNodeReport] = [:]
        var transformedSectionsById: [String: ConcretePromptSection] = [:]

        for planned in sortedPlanActions {
            guard let section = sectionsById[planned.nodeId] else { continue }

            let output = await applyAction(planned, section: section, compressor: compressor)
            transformedSectionsById[planned.nodeId] = output.section
            reportsById[planned.nodeId] = output.report
        }

        var resultingSections: [ConcretePromptSection] = []
        var reports: [CompressionNodeReport] = []

        for section in sections {
            if let transformed = transformedSectionsById[section.id] {
                if transformed.estimatedTokens > 0 || transformed.compression != .drop {
                    resultingSections.append(transformed)
                }
            } else {
                resultingSections.append(section)
            }

            if let report = reportsById[section.id] {
                reports.append(report)
            } else if let planned = actionById[section.id] {
                reports.append(CompressionNodeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: planned.action,
                    beforeTokens: planned.estimatedTokens,
                    afterTokens: planned.estimatedTokens,
                    cacheHit: false,
                    fallbackReason: nil
                ))
            }
        }

        return StructuredExecutionResult(
            sections: resultingSections,
            report: CompressionReport(nodeReports: reports)
        )
    }

    private func applyAction(
        _ planned: PlannedNodeAction,
        section: ConcretePromptSection,
        compressor: SectionCompressor?
    ) async -> (section: ConcretePromptSection, report: CompressionNodeReport) {
        switch planned.action {
        case .keep:
            return (
                section,
                CompressionNodeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: planned.action,
                    beforeTokens: planned.estimatedTokens,
                    afterTokens: planned.estimatedTokens,
                    cacheHit: false,
                    fallbackReason: nil
                )
            )

        case let .truncate(limit, _):
            let constrained = section.constrained(to: max(0, limit))
            return (
                constrained,
                CompressionNodeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: planned.action,
                    beforeTokens: planned.estimatedTokens,
                    afterTokens: constrained.estimatedTokens,
                    cacheHit: false,
                    fallbackReason: nil
                )
            )

        case let .summarize(targetTokens, reason):
            guard let compressor,
                  let content = await section.renderText(),
                  !content.isEmpty
            else {
                let dropped = section.dropped()
                return (
                    dropped,
                    CompressionNodeReport(
                        nodeId: planned.nodeId,
                        path: planned.path,
                        action: .drop,
                        beforeTokens: planned.estimatedTokens,
                        afterTokens: 0,
                        cacheHit: false,
                        fallbackReason: "missing_compressor_or_content"
                    )
                )
            }

            let cacheKey = SummaryCacheKey(nodeHash: planned.nodeHash, targetTokens: targetTokens)
            if let cached = summaryCache[cacheKey] {
                let summaryTokens = max(1, cached.count / 4)
                return (
                    section.summarized(cached, estimatedTokens: summaryTokens),
                    CompressionNodeReport(
                        nodeId: planned.nodeId,
                        path: planned.path,
                        action: planned.action,
                        beforeTokens: planned.estimatedTokens,
                        afterTokens: summaryTokens,
                        cacheHit: true,
                        fallbackReason: nil
                    )
                )
            }

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
                    let dropped = section.dropped()
                    return (
                        dropped,
                        CompressionNodeReport(
                            nodeId: planned.nodeId,
                            path: planned.path,
                            action: .drop,
                            beforeTokens: planned.estimatedTokens,
                            afterTokens: 0,
                            cacheHit: false,
                            fallbackReason: "empty_summary"
                        )
                    )
                }

                insertSummaryCache(summary, for: cacheKey)
                let summaryTokens = max(1, summary.count / 4)
                return (
                    section.summarized(summary, estimatedTokens: summaryTokens),
                    CompressionNodeReport(
                        nodeId: planned.nodeId,
                        path: planned.path,
                        action: planned.action,
                        beforeTokens: planned.estimatedTokens,
                        afterTokens: summaryTokens,
                        cacheHit: false,
                        fallbackReason: nil
                    )
                )
            } catch {
                let dropped = section.dropped()
                return (
                    dropped,
                    CompressionNodeReport(
                        nodeId: planned.nodeId,
                        path: planned.path,
                        action: .drop,
                        beforeTokens: planned.estimatedTokens,
                        afterTokens: 0,
                        cacheHit: false,
                        fallbackReason: "summary_failed"
                    )
                )
            }

        case .drop:
            let dropped = section.dropped()
            return (
                dropped,
                CompressionNodeReport(
                    nodeId: planned.nodeId,
                    path: planned.path,
                    action: .drop,
                    beforeTokens: planned.estimatedTokens,
                    afterTokens: 0,
                    cacheHit: false,
                    fallbackReason: nil
                )
            )
        }
    }

    private func insertSummaryCache(_ summary: String, for key: SummaryCacheKey) {
        if summaryCache[key] == nil {
            summaryCacheInsertionOrder.append(key)
        }
        summaryCache[key] = summary

        while summaryCacheInsertionOrder.count > maxSummaryCacheEntries {
            let evicted = summaryCacheInsertionOrder.removeFirst()
            summaryCache.removeValue(forKey: evicted)
        }
    }
}
