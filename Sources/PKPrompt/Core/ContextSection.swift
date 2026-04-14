import Foundation

/// Defines the stability of a section's content across requests.
/// Used to order sections to maximize LLM prompt caching effectiveness.
public enum CachePolicy: Sendable, Comparable {
    /// Content remains stable across multiple turns (e.g., system instructions, agent identity).
    /// These are placed earliest in the prompt to create a consistent cache prefix.
    case stable
    /// Content changes occasionally or between sessions (e.g., tools, workspace environment).
    case semiStable
    /// Content changes with every request (e.g., latest user query, recent chat history).
    case volatile
}

/// Defines how a section should be handled when the total prompt token budget is exceeded.
public enum CompressionStrategy: Sendable, Equatable {
    /// Never compress or omit this section; it is critical for the prompt.
    case keep

    /// Truncate the section text to fit the budget.
    /// - Parameter tail: If true, truncate from the end. If false, truncate from the beginning.
    case truncate(tail: Bool)

    /// Attempt to summarize the content using a secondary LLM pass.
    case summarize

    /// Omit the entire section if it cannot fit within the allocated budget.
    case drop
}

/// Describes the structural nature of a section's content.
public enum ContextSectionType: Sendable {
    /// A continuous block of text.
    case text

    /// A structured list of distinct items.
    case list
}

/// A protocol defining a distinct component of an LLM prompt.
/// Implementations are responsible for rendering their specific context into a string.
public protocol ContextSection: Sendable {
    /// A unique identifier for this section type (e.g., "system", "history").
    var id: String { get }

    /// The priority of the section. Higher values typically result in earlier placement
    /// or protected status during token budget allocation.
    var priority: Int { get }

    /// An estimate of the number of tokens required to represent this section.
    var estimatedTokens: Int { get }

    /// The strategy to employ if the section must be compressed to fit a token limit.
    var strategy: CompressionStrategy { get }

    /// The structural type of the content.
    var type: ContextSectionType { get }

    /// A hint about how frequently the content changes, used for cache optimization.
    var cachePolicy: CachePolicy { get }

    /// Renders the section into its final string representation.
    /// - Returns: The rendered string, or nil if the section is empty or irrelevant.
    func render() async -> String?

    /// Renders the section, optionally applying a token constraint.
    /// - Parameter tokens: The maximum number of tokens allowed for the rendered output.
    /// - Returns: The rendered (and potentially truncated/summarized) string.
    func render(constrainedTo tokens: Int?) async -> String?

    /// Returns a version of this section that adheres to a specific token limit.
    /// - Parameter tokens: The token limit to enforce.
    /// - Returns: A new section that fits within the budget.
    func constrained(to tokens: Int) -> ContextSection
}

/// Default implementations for the `ContextSection` protocol.
public extension ContextSection {
    /// Default strategy is to keep the section as is.
    var strategy: CompressionStrategy {
        .keep
    }

    /// Default content type is simple text.
    var type: ContextSectionType {
        .text
    }

    /// Default cache policy is volatile.
    var cachePolicy: CachePolicy {
        .volatile
    }

    /// Default implementation that ignores constraints and calls `render()`.
    func render(constrainedTo tokens: Int?) async -> String? {
        guard let tokens else {
            return await render()
        }

        guard let content = await render(), !content.isEmpty else {
            return nil
        }

        let estimatedTokens = max(1, content.count / 4)
        guard estimatedTokens > tokens else {
            return content
        }

        guard case let .truncate(tail) = strategy else {
            return content
        }

        let charLimit = max(0, tokens * 4)
        if charLimit == 0 {
            return nil
        }

        if tail {
            return String(content.prefix(charLimit)) + "\n... [Truncated]"
        }
        return "... [Truncated]\n" + String(content.suffix(charLimit))
    }

    /// Default implementation that wraps the section in a `ConstrainedSection` wrapper.
    func constrained(to tokens: Int) -> ContextSection {
        ConstrainedSection(wrapped: self, limit: tokens)
    }
}

/// A decorator that enforces a token limit on a wrapped `ContextSection`.
public struct ConstrainedSection: ContextSection {
    /// The original section being constrained.
    public let wrapped: ContextSection
    /// The maximum number of tokens allowed.
    public let limit: Int

    public var id: String {
        wrapped.id
    }

    public var priority: Int {
        wrapped.priority
    }

    public var estimatedTokens: Int {
        min(wrapped.estimatedTokens, limit)
    }

    public var strategy: CompressionStrategy {
        wrapped.strategy
    }

    public var type: ContextSectionType {
        wrapped.type
    }

    /// Initializes a new constrained section wrapper.
    /// - Parameters:
    ///   - wrapped: The section to constrain.
    ///   - limit: The token limit.
    public init(wrapped: ContextSection, limit: Int) {
        self.wrapped = wrapped
        self.limit = limit
    }

    /// Renders the wrapped section using the specified limit.
    public func render() async -> String? {
        await wrapped.render(constrainedTo: limit)
    }

    /// Renders the wrapped section using the more restrictive of the two limits.
    public func render(constrainedTo tokens: Int?) async -> String? {
        let effectiveLimit = tokens.map { min($0, limit) } ?? limit
        return await wrapped.render(constrainedTo: effectiveLimit)
    }

    /// Returns a new constrained section with an even more restrictive limit if necessary.
    public func constrained(to tokens: Int) -> ContextSection {
        ConstrainedSection(wrapped: wrapped, limit: min(limit, tokens))
    }
}
