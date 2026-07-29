import Foundation
import PKShared

/// A validated, ordered prompt artifact built from concrete prompt sections.
///
/// `AssembledPrompt` is the bridge between declarative prompt composition and concrete output.
/// It preserves the concrete section metadata used by downstream systems and renders those
/// sections into a single canonical ``RenderedPrompt`` product that can be reused by downstream
/// projections such as provider message arrays.
public struct AssembledPrompt: Sendable {
    /// Compatibility alias for prompt assembly validation failures.
    public typealias ValidationError = PromptAssemblyError

    // MARK: - Properties

    /// Ordered concrete sections that make up this prompt.
    ///
    /// Sections are sorted during initialization by cache policy, then priority, while preserving
    /// source order as a final tiebreaker.
    public let sections: [PromptSection]

    /// Optional compression details captured when assembly applied a token budget.
    public let compressionReport: CompressionReport?

    /// Estimated token count across the ordered concrete sections.
    public var estimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Creates an assembled prompt from concrete sections after validating prompt shape.
    ///
    /// - Parameters:
    ///   - sections: Concrete prompt sections to validate and order.
    ///   - compressionReport: Optional report describing compression applied during assembly.
    /// - Throws: ``ValidationError`` when duplicate section identifiers are present or the prompt
    ///   contains more than one user-query section.
    public init(
        sections: [PromptSection],
        compressionReport: CompressionReport? = nil
    ) throws {
        self.sections = try PromptSection.validateAndSort(sections: sections)
        self.compressionReport = compressionReport
    }

    /// Renders the prompt once and returns its canonical output product.
    ///
    /// Prefer this API when multiple downstream consumers need access to the same rendered prompt,
    /// such as plain-text rendering, snapshot recording, and provider message generation.
    public func render() async -> RenderedPrompt {
        var renderedSections: [RenderedPrompt.Section] = []
        var sectionsByID: [String: String] = [:]
        var stringParts: [String] = []

        for section in sections {
            guard let renderedSection = await section.rendered() else {
                continue
            }
            renderedSections.append(renderedSection)

            guard let text = renderedTextContent(for: renderedSection),
                  !text.isEmpty
            else {
                continue
            }

            sectionsByID[renderedSection.id] = text
            stringParts.append(text)
        }

        return RenderedPrompt(
            sections: renderedSections,
            string: stringParts.joined(separator: "\n\n---\n\n"),
            sectionsByID: sectionsByID,
            compressionReport: compressionReport
        )
    }

    private func renderedTextContent(for section: RenderedPrompt.Section)
        -> String?
    {
        switch section.content {
        case let .text(content):
            return content
        case let .messages(messages):
            let content =
                messages
                    .map(Self.formatHistoryMessage)
                    .joined(separator: "\n\n")
            return content.isEmpty ? nil : content
        }
    }

    private static func formatHistoryMessage(_ message: Message) -> String {
        switch message.role {
        case .user:
            return "User: \(message.content)"
        case .assistant:
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                return "Assistant: <think>\(reasoning)</think>\n\(message.content)"
            }
            return "Assistant: \(message.content)"
        case .system:
            return "System: \(message.content)"
        case .tool:
            return "Tool: \(message.content)"
        case .summary:
            return "Summary: \(message.content)"
        }
    }
}
