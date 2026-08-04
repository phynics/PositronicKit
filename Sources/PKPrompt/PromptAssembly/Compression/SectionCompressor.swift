import Foundation

/// Node-aware request to summarize a single node's content, passed to
/// ``SectionCompressor/summarize(request:)`` so an injected summarizer can use node
/// identity/path context rather than just raw text.
public struct SummaryRequest: Sendable, Equatable {
    /// The ID of the node being summarized.
    public let nodeID: String
    /// The ID of the node being summarized.
    @available(*, deprecated, renamed: "nodeID")
    public var nodeId: String { nodeID }
    /// The node's structural path within the prompt tree.
    public let path: [String]
    /// The full text to summarize.
    public let text: String
    /// The approximate token length the summary should target.
    public let targetTokens: Int
    /// Why this node is being summarized.
    public let reason: CompressionReason

    /// Creates a node-aware summary request.
    public init(nodeID: String, path: [String], text: String, targetTokens: Int, reason: CompressionReason) {
        self.nodeID = nodeID
        self.path = path
        self.text = text
        self.targetTokens = targetTokens
        self.reason = reason
    }

    /// Creates a summary request using the legacy node identifier spelling.
    @available(*, deprecated, message: "Use init(nodeID:path:text:targetTokens:reason:).")
    public init(nodeId: String, path: [String], text: String, targetTokens: Int, reason: CompressionReason) {
        self.init(nodeID: nodeId, path: path, text: text, targetTokens: targetTokens, reason: reason)
    }
}

/// Protocol for a service that can compress/summarize text for token budget management
public protocol SectionCompressor: Sendable {
    /// Summarize the given text to reduce its token count
    /// - Parameter text: The text to summarize
    /// - Returns: A shortened version of the text
    func summarize(_ text: String) async throws -> String

    /// Summarize a node-aware structured request.
    /// Default implementation delegates to `summarize(_:)`.
    func summarize(request: SummaryRequest) async throws -> String
}

public extension SectionCompressor {
    func summarize(request: SummaryRequest) async throws -> String {
        try await summarize(request.text)
    }
}
