import Foundation

public struct StructuredCompressionPlanner: Sendable {
    public init() {}

    public func plan(
        nodes: [StructuredCompressionNode],
        availableTokens: Int,
        diff: StructuredDiffHint?
    ) -> StructuredCompressionPlan {
        precondition(
            Set(nodes.map(\.id)).count == nodes.count,
            "Duplicate structured node ids are not supported"
        )
        let totalEstimated = nodes.reduce(0) { $0 + $1.estimatedTokens }
        guard totalEstimated > availableTokens else {
            return StructuredCompressionPlan(
                availableTokens: availableTokens,
                totalEstimatedTokens: totalEstimated,
                nodeActions: nodes.map {
                    PlannedNodeAction(
                        nodeId: $0.id,
                        path: $0.path,
                        nodeHash: $0.nodeHash,
                        strategy: $0.strategy,
                        estimatedTokens: $0.estimatedTokens,
                        action: .keep
                    )
                }
            )
        }

        let changedSet = Set((diff?.changedNodePaths ?? []).map(pathKey))
        let stableSet = Set((diff?.stableNodePaths ?? []).map(pathKey))

        let rankedNodes = nodes.sorted { lhs, rhs in
            let lhsScore = score(node: lhs, changedSet: changedSet, stableSet: stableSet)
            let rhsScore = score(node: rhs, changedSet: changedSet, stableSet: stableSet)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.cachePolicy != rhs.cachePolicy { return lhs.cachePolicy > rhs.cachePolicy }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.path.lexicographicallyPrecedes(rhs.path)
        }

        var remaining = availableTokens
        var actionsById: [String: PlannedNodeAction] = [:]

        for node in rankedNodes {
            let action = decideAction(for: node, remainingTokens: remaining, isStableNode: stableSet.contains(pathKey(node.path)))
            let planned = PlannedNodeAction(
                nodeId: node.id,
                path: node.path,
                nodeHash: node.nodeHash,
                strategy: node.strategy,
                estimatedTokens: node.estimatedTokens,
                action: action
            )
            actionsById[node.id] = planned

            switch action {
            case .keep:
                remaining -= node.estimatedTokens
            case let .truncate(limit, _):
                remaining -= max(0, limit)
            case let .summarize(targetTokens, _):
                remaining -= max(0, targetTokens)
            case .drop:
                break
            }
        }

        let orderedActions = nodes.compactMap { actionsById[$0.id] }
        return StructuredCompressionPlan(
            availableTokens: availableTokens,
            totalEstimatedTokens: totalEstimated,
            nodeActions: orderedActions
        )
    }

    private func score(node: StructuredCompressionNode, changedSet: Set<String>, stableSet: Set<String>) -> Int {
        var value = node.priority * 10
        let key = pathKey(node.path)
        if changedSet.contains(key) {
            value += 1_000
        } else if stableSet.contains(key) {
            value -= 500
        }
        switch node.cachePolicy {
        case .volatile: value += 300
        case .semiStable: value += 150
        case .stable: value += 0
        }
        return value
    }

    private func decideAction(for node: StructuredCompressionNode, remainingTokens: Int, isStableNode: Bool) -> CompressionAction {
        if isStableNode, node.strategy != .keep {
            return .drop
        }

        if node.estimatedTokens <= remainingTokens {
            return .keep
        }

        switch node.strategy {
        case .keep:
            return .keep
        case let .truncate(tail):
            guard remainingTokens > 0 else { return .drop }
            return .truncate(limit: remainingTokens, tail: tail)
        case .summarize:
            guard remainingTokens > 0 else { return .drop }
            let target = max(1, min(remainingTokens, node.estimatedTokens / 3))
            return .summarize(targetTokens: target, reason: .budgetReduction)
        case .drop:
            return .drop
        }
    }

    private func pathKey(_ path: [String]) -> String {
        path.map { "\($0.count):\($0)" }.joined(separator: "|")
    }
}
