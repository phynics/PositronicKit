import Foundation

public struct SummaryRequest: Sendable, Equatable {
    public let nodeId: String
    public let path: [String]
    public let text: String
    public let targetTokens: Int
    public let reason: CompressionReason

    public init(nodeId: String, path: [String], text: String, targetTokens: Int, reason: CompressionReason) {
        self.nodeId = nodeId
        self.path = path
        self.text = text
        self.targetTokens = targetTokens
        self.reason = reason
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
