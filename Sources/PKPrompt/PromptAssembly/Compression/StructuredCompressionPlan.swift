import Foundation

/// Why a compression action was chosen for a node. Currently there is a single reason;
/// the type exists so `PlannedNodeAction`/`CompressionAction` can attach a rationale
/// without hardcoding a string, and to leave room for future reasons.
public enum CompressionReason: String, Sendable, Equatable {
    /// The node was compressed to make the assembled prompt fit the available token budget.
    case budgetReduction
}

/// The concrete action the compression planner decided to take for a node.
public enum CompressionAction: Sendable, Equatable {
    /// Keep the node's content unchanged.
    case keep
    /// Replace the node's content with a summary of roughly `targetTokens` tokens, `reason`
    /// recording why the summary was needed.
    case summarize(targetTokens: Int, reason: CompressionReason)
    /// Truncate the node's content to `limit` tokens; `tail` selects which end is kept.
    case truncate(limit: Int, tail: Bool)
    /// Drop the node's content entirely.
    case drop
}

/// A candidate node the ``StructuredCompressionPlanner`` ranks and decides an action for.
public struct StructuredCompressionNode: Sendable, Equatable {
    /// The node's stable identifier.
    public let id: String
    /// The node's structural path within the prompt tree.
    public let path: [String]
    /// Content fingerprint (via ``StableHash``), used to detect whether the node changed
    /// since a prior diff/plan.
    public let nodeHash: UInt64
    /// The node's priority; higher priority nodes are preferred to keep under budget pressure.
    public let priority: Int
    public let cachePolicy: CachePolicy
    public let strategy: CompressionStrategy
    /// Estimated token cost of the node's content at full size.
    public let estimatedTokens: Int

    public init(
        id: String,
        path: [String],
        nodeHash: UInt64,
        priority: Int,
        cachePolicy: CachePolicy,
        strategy: CompressionStrategy,
        estimatedTokens: Int
    ) {
        self.id = id
        self.path = path
        self.nodeHash = nodeHash
        self.priority = priority
        self.cachePolicy = cachePolicy
        self.strategy = strategy
        self.estimatedTokens = estimatedTokens
    }
}

/// The planner's decision for a single node, produced by ``StructuredCompressionPlanner/plan``
/// and applied by `StructuredCompressionExecutor`.
public struct PlannedNodeAction: Sendable, Equatable {
    /// The id of the node this decision applies to.
    public let nodeId: String
    /// The node's structural path within the prompt tree.
    public let path: [String]
    /// Content fingerprint of the node at plan time.
    public let nodeHash: UInt64
    /// The node's declared compression strategy (from `CompressionStrategy`), used by the
    /// executor when it needs to fall back to render-time constraints.
    public let strategy: CompressionStrategy
    /// Estimated token cost of the node's content at full size.
    public let estimatedTokens: Int
    /// The action decided for this node.
    public let action: CompressionAction

    public init(
        nodeId: String,
        path: [String],
        nodeHash: UInt64,
        strategy: CompressionStrategy,
        estimatedTokens: Int,
        action: CompressionAction
    ) {
        self.nodeId = nodeId
        self.path = path
        self.nodeHash = nodeHash
        self.strategy = strategy
        self.estimatedTokens = estimatedTokens
        self.action = action
    }
}

/// The full compression decision for a set of nodes, produced by
/// ``StructuredCompressionPlanner/plan``.
public struct StructuredCompressionPlan: Sendable, Equatable {
    /// The token budget the plan was computed against.
    public let availableTokens: Int
    /// Sum of all nodes' estimated tokens at full size, before any compression.
    public let totalEstimatedTokens: Int
    /// Per-node decisions, in the same order as the input nodes.
    public let nodeActions: [PlannedNodeAction]

    public init(availableTokens: Int, totalEstimatedTokens: Int, nodeActions: [PlannedNodeAction]) {
        self.availableTokens = availableTokens
        self.totalEstimatedTokens = totalEstimatedTokens
        self.nodeActions = nodeActions
    }
}

/// Cached identity of a previously-rendered node (path + content hash), used to detect
/// which nodes changed since the last render when building a ``StructuredDiffHint``.
public struct StructuredNodeMetadata: Sendable, Equatable {
    /// The node's structural path within the prompt tree.
    public let path: [String]
    /// Content fingerprint of the node as previously observed.
    public let nodeHash: UInt64

    public init(path: [String], nodeHash: UInt64) {
        self.path = path
        self.nodeHash = nodeHash
    }
}

/// Which nodes changed vs. stayed the same since a prior render, used by
/// ``StructuredCompressionPlanner`` to bias compression toward changed content and away
/// from unchanged (already-cached) content.
public struct StructuredDiffHint: Sendable, Equatable {
    /// Paths of nodes whose content changed since the last render.
    public let changedNodePaths: [[String]]
    /// Paths of nodes confirmed unchanged since the last render.
    public let stableNodePaths: [[String]]

    public init(
        changedNodePaths: [[String]],
        stableNodePaths: [[String]]
    ) {
        self.changedNodePaths = changedNodePaths
        self.stableNodePaths = stableNodePaths
    }
}
