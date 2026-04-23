import Foundation

public struct CompressionNodeReport: Sendable, Equatable {
    public let nodeId: String
    public let path: [String]
    public let action: CompressionAction
    public let beforeTokens: Int
    public let afterTokens: Int
    public let cacheHit: Bool
    public let fallbackReason: String?

    public init(
        nodeId: String,
        path: [String],
        action: CompressionAction,
        beforeTokens: Int,
        afterTokens: Int,
        cacheHit: Bool,
        fallbackReason: String?
    ) {
        self.nodeId = nodeId
        self.path = path
        self.action = action
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.cacheHit = cacheHit
        self.fallbackReason = fallbackReason
    }
}

public struct CompressionReport: Sendable, Equatable {
    public let nodeReports: [CompressionNodeReport]

    public init(nodeReports: [CompressionNodeReport]) {
        self.nodeReports = nodeReports
    }
}

public struct StructuredExecutionResult: Sendable {
    public let sections: [PromptSection]
    public let report: CompressionReport

    public init(sections: [PromptSection], report: CompressionReport) {
        self.sections = sections
        self.report = report
    }
}
