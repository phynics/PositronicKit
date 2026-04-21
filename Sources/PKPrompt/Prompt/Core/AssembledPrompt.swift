import Foundation
import PKShared

/// A validated, ordered prompt artifact built from resolved prompt sections.
///
/// `AssembledPrompt` is the bridge between declarative prompt composition and concrete output.
/// It preserves the resolved section metadata used by downstream systems and renders those
/// sections into a single canonical ``RenderedPrompt`` product that can be reused by downstream
/// projections such as provider message arrays.
public struct AssembledPrompt: Sendable {
    // MARK: - Internal Types

    /// A rendered prompt section paired with its stable identifier and semantic role.
    ///
    /// Instances of `Section` only include sections whose render closure produced concrete output.
    public struct Section: Sendable {
        /// Stable section identifier inherited from the resolved prompt graph.
        public let id: String

        /// Semantic role that determines how downstream renderers treat this section.
        public let role: PromptSectionRole

        /// Concrete rendered content for the section.
        public let content: RenderedPromptSection.SectionContent
    }

    /// Errors raised when resolved sections cannot form a valid assembled prompt.
    public enum ValidationError: Error, Sendable, Equatable {
        /// Two or more resolved sections shared the same stable identifier.
        case duplicateSectionIDs([String])

        /// More than one resolved section declared itself as the active user query.
        case multipleUserQuerySections([String])
    }

    /// Canonical prompt output derived from a single rendering pass.
    ///
    /// Use this type when multiple consumers need to work from the same rendered prompt without
    /// re-running section render closures. The projections stored here are intentionally aligned:
    /// they all come from the same ordered section list.
    public struct RenderedPrompt: Sendable {
        /// Rendered sections in canonical prompt order.
        public let sections: [Section]

        /// Canonical plain-text prompt representation built from ``sections``.
        ///
        /// Text sections contribute their raw text, while message sections are formatted into the
        /// plain-text transcript representation used by `AssembledPrompt`.
        public let string: String

        /// Canonical plain-text content for each rendered section keyed by section ID.
        ///
        /// This snapshot is intended for hashing, journaling, and other section-oriented consumers
        /// that need a stable textual representation of the rendered prompt.
        public let sectionsByID: [String: String]
    }

    // MARK: - Properties

    /// Ordered resolved sections that make up this prompt.
    ///
    /// Sections are sorted during initialization by cache policy, then priority, while preserving
    /// source order as a final tiebreaker.
    public let resolvedSections: [ResolvedPromptSection]

    /// Optional compression details captured when assembly applied a token budget.
    public let compressionReport: CompressionReport?

    /// Estimated token count across the ordered resolved sections.
    public var estimatedTokens: Int {
        resolvedSections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Creates an assembled prompt from resolved sections after validating prompt shape.
    ///
    /// - Parameters:
    ///   - resolvedSections: Concrete prompt sections to validate and order.
    ///   - compressionReport: Optional report describing compression applied during assembly.
    /// - Throws: ``ValidationError`` when duplicate section identifiers are present or the prompt
    ///   contains more than one user-query section.
    public init(
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil,
    ) throws {
        try Self.validatePromptShape(in: resolvedSections)
        self.resolvedSections = AssembledPrompt.sortResolvedSections(resolvedSections)
        self.compressionReport = compressionReport
    }

    /// Renders the prompt once and returns its canonical output product.
    ///
    /// Prefer this API when multiple downstream consumers need access to the same rendered prompt,
    /// such as plain-text rendering, snapshot recording, and provider message generation.
    public func rendered() async -> RenderedPrompt {
        var renderedSections: [Section] = []
        var sectionsByID: [String: String] = [:]
        var stringParts: [String] = []

        for section in resolvedSections {
            guard let content = await section.renderedContent() else {
                continue
            }

            let renderedSection = Section(id: section.id, role: section.role, content: content)
            renderedSections.append(renderedSection)

            guard let text = textContent(for: renderedSection), !text.isEmpty else {
                continue
            }

            sectionsByID[renderedSection.id] = text
            stringParts.append(text)
        }

        return RenderedPrompt(
            sections: renderedSections,
            string: stringParts.joined(separator: "\n\n---\n\n"),
            sectionsByID: sectionsByID
        )
    }

    // MARK: - Private Utilities
    private static func sortResolvedSections(_ sections: [ResolvedPromptSection]) -> [ResolvedPromptSection] {
        sections.enumerated().sorted { lhs, rhs in
            if lhs.element.cachePolicy != rhs.element.cachePolicy {
                return lhs.element.cachePolicy < rhs.element.cachePolicy
            }
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func validatePromptShape(in sections: [ResolvedPromptSection]) throws {
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw ValidationError.duplicateSectionIDs(duplicateIDs)
        }

        let userQueryIDs = sections
            .filter { $0.role == .userQuery }
            .map(\.id)
            .sorted()

        guard userQueryIDs.count <= 1 else {
            throw ValidationError.multipleUserQuerySections(userQueryIDs)
        }
    }

    private func textContent(for section: Section) -> String? {
        switch section.content {
        case let .text(content):
            return content
        case let .messages(messages):
            let content = messages
                .map(formatHistoryMessage)
                .joined(separator: "\n\n")
            return content.isEmpty ? nil : content
        }
    }

    private func formatHistoryMessage(_ message: Message) -> String {
        switch message.role {
        case .user:
            return "User: \(message.content)"
        case .assistant:
            if let think = message.think, !think.isEmpty {
                return "Assistant: <think>\(think)</think>\n\(message.content)"
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
