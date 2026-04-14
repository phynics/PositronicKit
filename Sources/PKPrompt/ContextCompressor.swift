import Foundation

/// Protocol for a service that can compress/summarize text for token budget management
public protocol SectionCompressor: Sendable {
    /// Summarize the given text to reduce its token count
    /// - Parameter text: The text to summarize
    /// - Returns: A shortened version of the text
    func summarize(_ text: String) async throws -> String
}
