import Foundation

/// A per-node outcome produced by compression flows.
///
/// `CompressionNodeReport` captures what happened to a single prompt section during
/// token-budget enforcement or structured compression. It records the chosen action,
/// token counts before/after, whether a cache was hit, and any fallback reason when
/// a requested strategy couldn't be applied.
public struct CompressionNodeReport: Sendable, Equatable, Codable {
    /// Stable identifier of the source section/node.
    public let nodeId: String
    /// Stable path to the section in the composed prompt tree.
    public let path: [String]
    /// The compression action that was applied to this node.
    public let action: CompressionAction
    /// Estimated token count before compression was applied.
    public let beforeTokens: Int
    /// Estimated token count after compression was applied.
    public let afterTokens: Int
    /// Whether the result was served from cache instead of recomputing.
    public let cacheHit: Bool
    /// Reason a fallback occurred (e.g., missing compressor or budget), if any.
    public let fallbackReason: String?

    /// Create a node-level compression report.
    /// - Parameters:
    ///   - nodeId: Stable identifier of the affected section.
    ///   - path: Stable path to the section in the composed prompt tree.
    ///   - action: The compression action that was applied.
    ///   - beforeTokens: Estimated tokens before compression.
    ///   - afterTokens: Estimated tokens after compression.
    ///   - cacheHit: Whether a cached result was used.
    ///   - fallbackReason: Reason for fallback when action couldn't be honored.
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

/// Aggregated compression outcome for an entire prompt render.
///
/// Contains one `CompressionNodeReport` per section that participated in compression.
public struct CompressionReport: Sendable, Equatable, Codable {
    /// Per-node reports in render order (when available).
    public let nodeReports: [CompressionNodeReport]

    /// Initialize a compression report with per-node entries.
    public init(nodeReports: [CompressionNodeReport]) {
        self.nodeReports = nodeReports
    }
}

/// Result of executing a structured compression plan.
///
/// Returns the transformed sections and the detailed compression report describing
/// what actions were taken for each node.
public struct StructuredExecutionResult: Sendable {
    /// Sections after applying the structured plan/execution.
    public let sections: [PromptSection]
    /// Detailed compression report collected during execution.
    public let report: CompressionReport

    /// Create a structured execution result with transformed sections and report.
    public init(sections: [PromptSection], report: CompressionReport) {
        self.sections = sections
        self.report = report
    }
}

/// The verified result of applying a token budget to prompt sections.
public struct TokenBudgetResult: Sendable {
    /// Sections after compression.
    public let sections: [PromptSection]
    /// Detailed compression report, if compression was needed.
    public let report: CompressionReport?
    /// The estimated token count of the returned sections.
    public let estimatedTokens: Int
    /// The hard token limit used for this result.
    public let availableTokens: Int

    public init(
        sections: [PromptSection],
        report: CompressionReport?,
        estimatedTokens: Int,
        availableTokens: Int
    ) {
        self.sections = sections
        self.report = report
        self.estimatedTokens = estimatedTokens
        self.availableTokens = availableTokens
    }
}
