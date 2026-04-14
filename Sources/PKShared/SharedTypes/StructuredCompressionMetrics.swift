import Foundation

public struct StructuredCompressionNodeMetric: Codable, Sendable, Equatable {
    public let nodeId: String
    public let path: [String]
    public let action: String
    public let beforeTokens: Int
    public let afterTokens: Int
    public let cacheHit: Bool

    public init(
        nodeId: String,
        path: [String],
        action: String,
        beforeTokens: Int,
        afterTokens: Int,
        cacheHit: Bool
    ) {
        self.nodeId = nodeId
        self.path = path
        self.action = action
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.cacheHit = cacheHit
    }
}

public struct StructuredCompressionMetrics: Codable, Sendable, Equatable {
    public let totalNodes: Int
    public let summarizedNodes: Int
    public let droppedNodes: Int
    public let cacheHits: Int
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
