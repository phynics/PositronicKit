import Foundation

/// Represents a fully assembled LLM prompt consisting of multiple ordered sections.
/// Sections are automatically sorted based on their cache policy and priority upon initialization.
public struct Prompt: Sendable {
    /// The ordered collection of sections that make up the prompt.
    public let sections: [ContextSection]
    public let compressionReport: CompressionReport?

    /// Initializes a new prompt from an array of sections.
    /// - Parameter sections: The raw sections to include. They will be sorted for optimal prompt construction.
    public init(sections: [ContextSection], compressionReport: CompressionReport? = nil) {
        self.sections = sections.sorted {
            if $0.cachePolicy != $1.cachePolicy {
                return $0.cachePolicy < $1.cachePolicy // stable < semiStable < volatile
            }
            return $0.priority > $1.priority
        }
        self.compressionReport = compressionReport
    }

    /// Initializes a new prompt using a declarative `@ContextBuilder` block.
    /// - Parameter content: A closure that returns an array of sections.
    public init(@ContextBuilder _ content: () -> [ContextSection]) {
        self.init(sections: content())
    }

    /// Renders the full prompt string by joining all non-empty sections with delimiters.
    /// - Returns: The final rendered prompt string.
    public func render() async -> String {
        var parts: [String] = []
        for section in sections {
            if let content = await renderedContent(for: section), !content.isEmpty {
                parts.append(content)
            }
        }
        return joinedRenderedParts(parts)
    }

    /// Render all sections once, returning a map of section ID to rendered content.
    /// Use this to avoid double-rendering when content is needed by multiple consumers
    /// (e.g. `toMessages()` and `TimelinePromptHistory.record()`).
    public func renderAll() async -> [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            if let content = await section.render(), !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }

    /// Renders the full prompt string using a pre-rendered content map.
    /// - Parameter preRendered: A map of section IDs to their already-rendered content.
    /// - Returns: The final rendered prompt string.
    public func render(preRendered: [String: String]) -> String {
        var parts: [String] = []
        for section in sections {
            if let content = renderedContent(for: section, preRendered: preRendered), !content.isEmpty {
                parts.append(content)
            }
        }
        return joinedRenderedParts(parts)
    }

    @available(*, deprecated, renamed: "renderAll")
    public func structuredContext() async -> [String: String] {
        await renderAll()
    }

    /// An estimate of the total number of tokens for all sections in the prompt.
    public var estimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    private func renderedContent(for section: ContextSection) async -> String? {
        await section.render()
    }

    private func renderedContent(for section: ContextSection, preRendered: [String: String]) -> String? {
        preRendered[section.id]
    }

    private func joinedRenderedParts(_ parts: [String]) -> String {
        parts.joined(separator: "\n\n---\n\n")
    }
}
