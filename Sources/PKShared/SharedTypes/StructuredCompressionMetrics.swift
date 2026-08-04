import Foundation

/// Per-node outcome of a compression pass, used for observability/diagnostics.
public struct StructuredCompressionNodeMetric: Codable, Sendable, Equatable {
    /// Identifier of the compressed node.
    public let nodeID: String
    /// The node's structural path within the prompt tree.
    public let path: [String]
    /// The compression action applied to the node (e.g. `"keep"`, `"truncate"`, `"summarize"`, `"drop"`).
    public let action: String
    /// Estimated token count for the node's content before compression.
    public let beforeTokens: Int
    /// Estimated token count for the node's content after compression.
    public let afterTokens: Int
    /// Whether this node's compressed output was served from cache rather than recomputed.
    public let cacheHit: Bool

    public init(
        nodeID: String,
        path: [String],
        action: String,
        beforeTokens: Int,
        afterTokens: Int,
        cacheHit: Bool
    ) {
        self.nodeID = nodeID
        self.path = path
        self.action = action
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.cacheHit = cacheHit
    }

    /// Creates a node metric using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(nodeID:path:action:beforeTokens:afterTokens:cacheHit:).")
    public init(
        nodeId: String,
        path: [String],
        action: String,
        beforeTokens: Int,
        afterTokens: Int,
        cacheHit: Bool
    ) {
        self.init(
            nodeID: nodeId,
            path: path,
            action: action,
            beforeTokens: beforeTokens,
            afterTokens: afterTokens,
            cacheHit: cacheHit
        )
    }

    /// The node identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "nodeID")
    public var nodeId: String { nodeID }

    private enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId"
        case path, action, beforeTokens, afterTokens, cacheHit
    }
}

/// Aggregate outcome of a structured-compression pass, used for observability/diagnostics.
public struct StructuredCompressionMetrics: Codable, Sendable, Equatable {
    /// Total number of nodes considered for compression.
    public let totalNodes: Int
    /// Number of nodes that were summarized.
    public let summarizedNodes: Int
    /// Number of nodes that were dropped entirely.
    public let droppedNodes: Int
    /// Number of nodes whose compressed output was served from cache.
    public let cacheHits: Int
    /// Per-node breakdown of the compression outcome.
    public let nodeMetrics: [StructuredCompressionNodeMetric]

    public init(
        totalNodes: Int,
        summarizedNodes: Int,
        droppedNodes: Int,
        cacheHits: Int,
        nodeMetrics: [StructuredCompressionNodeMetric]
    ) {
        self.totalNodes = totalNodes
        self.summarizedNodes = summarizedNodes
        self.droppedNodes = droppedNodes
        self.cacheHits = cacheHits
        self.nodeMetrics = nodeMetrics
    }
}
