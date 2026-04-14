import Foundation

public enum CompressionReason: String, Sendable, Equatable {
    case budgetReduction
}

public enum CompressionAction: Sendable, Equatable {
    case keep
    case summarize(targetTokens: Int, reason: CompressionReason)
    case truncate(limit: Int, tail: Bool)
    case drop
}

public struct StructuredCompressionNode: Sendable, Equatable {
    public let id: String
    public let path: [String]
    public let nodeHash: UInt64
    public let priority: Int
    public let cachePolicy: CachePolicy
    public let strategy: CompressionStrategy
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

public struct PlannedNodeAction: Sendable, Equatable {
    public let nodeId: String
    public let path: [String]
    public let nodeHash: UInt64
    public let strategy: CompressionStrategy
    public let estimatedTokens: Int
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

public struct StructuredCompressionPlan: Sendable, Equatable {
    public let availableTokens: Int
    public let totalEstimatedTokens: Int
    public let nodeActions: [PlannedNodeAction]

    public init(availableTokens: Int, totalEstimatedTokens: Int, nodeActions: [PlannedNodeAction]) {
        self.availableTokens = availableTokens
        self.totalEstimatedTokens = totalEstimatedTokens
        self.nodeActions = nodeActions
    }
}

public struct StructuredNodeMetadata: Sendable, Equatable {
    public let path: [String]
    public let nodeHash: UInt64

    public init(path: [String], nodeHash: UInt64) {
        self.path = path
        self.nodeHash = nodeHash
    }
}

public struct StructuredDiffHint: Sendable, Equatable {
    public let changedNodePaths: [[String]]
    public let stableNodePaths: [[String]]

    public init(
        changedNodePaths: [[String]],
        stableNodePaths: [[String]]
    ) {
        self.changedNodePaths = changedNodePaths
        self.stableNodePaths = stableNodePaths
    }
}
