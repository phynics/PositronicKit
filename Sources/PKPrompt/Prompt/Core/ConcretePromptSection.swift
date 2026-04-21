import Foundation
import PKShared

/// A fully resolved prompt node with inherited traits applied and a concrete render closure.
///
/// `ConcretePromptSection` is the concrete leaf artifact produced after prompt composition,
/// inheritance, and section lowering. It preserves stable identity and inherited metadata while
/// carrying the final render closure used by budgeting, compression, hashing, and prompt assembly.
public struct ConcretePromptSection: Sendable {
    /// A concrete rendered prompt section produced from a ``ConcretePromptSection``.
    public struct Rendered: Sendable {
        /// Stable section identifier inherited from the concrete prompt graph.
        public let id: String

        /// Semantic role that determines how downstream renderers treat this section.
        public let role: PromptSectionRole

        /// Concrete rendered content for the section.
        public let content: SectionContent
    }

    /// Concrete payload produced when a section is rendered.
    ///
    /// This payload shape is intentionally separate from ``PromptSectionType``. `type` records the
    /// authored section metadata, while `SectionContent` describes the concrete value a downstream
    /// consumer receives from the renderer.
    public enum SectionContent: Sendable, Equatable {
        /// Plain text content rendered for the section.
        case text(String)

        /// Structured message content, typically used for chat-history sections.
        case messages([Message])

        /// Plain text projection of the rendered payload.
        public var text: String? {
            if case let .text(content) = self {
                return content
            }
            return nil
        }

        /// Structured message projection of the rendered payload.
        public var messages: [Message]? {
            if case let .messages(messages) = self {
                return messages
            }
            return nil
        }
    }

    /// Signature for the final renderer attached to a concrete section.
    ///
    /// The optional integer is a soft token constraint used by compression flows. Returning `nil`
    /// indicates the section produces no output for the requested constraint.
    public typealias RenderClosure = @Sendable (Int?) async -> SectionContent?

    /// Stable section identifier.
    public let id: String

    /// Semantic role used by downstream prompt renderers.
    public let role: PromptSectionRole

    /// Effective priority after inherited modifiers have been applied.
    public let priority: Int

    /// Estimated token count used for budgeting before rendering.
    public let estimatedTokens: Int

    /// Effective compression strategy after inherited modifiers have been applied.
    public let compression: CompressionStrategy

    /// Authored section-type metadata.
    public let type: PromptSectionType

    /// Effective cache policy after inherited modifiers have been applied.
    public let cachePolicy: CachePolicy

    /// Stable path used by hashing, journaling, and structured compression.
    public let path: [String]

    /// Optional parent section identifier when the leaf originated from a composite subtree.
    public let parentID: String?

    /// Stores the final rendering behavior after resolution and any compression constraints.
    private let renderClosure: RenderClosure

    /// Creates a concrete section with its final inherited metadata and renderer.
    ///
    /// - Parameters:
    ///   - id: Stable section identifier.
    ///   - role: Semantic role used by downstream prompt renderers.
    ///   - priority: Effective priority after inheritance.
    ///   - estimatedTokens: Estimated token count used for budgeting.
    ///   - compression: Effective compression strategy after inheritance.
    ///   - type: Authored section-type metadata.
    ///   - cachePolicy: Effective cache policy after inheritance.
    ///   - path: Stable path used for hashing and journaling.
    ///   - parentID: Optional parent section identifier.
    ///   - render: Final renderer for the section.
    public init(
        id: String,
        role: PromptSectionRole,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy,
        type: PromptSectionType,
        cachePolicy: CachePolicy,
        path: [String],
        parentID: String? = nil,
        render: @escaping RenderClosure
    ) {
        self.id = id
        self.role = role
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.compression = compression
        self.type = type
        self.cachePolicy = cachePolicy
        self.path = path
        self.parentID = parentID
        self.renderClosure = render
    }

    /// Renders the section with an optional token constraint.
    ///
    /// - Parameter tokens: Maximum token budget to pass to the renderer. `nil` means unconstrained.
    /// - Returns: The concrete rendered payload, or `nil` when the section produces no output.
    public func renderedContent(constrainedTo tokens: Int? = nil) async -> SectionContent? {
        await renderClosure(tokens)
    }

    /// Renders this section into its concrete rendered counterpart.
    ///
    /// - Parameter tokens: Maximum token budget to pass to the renderer. `nil` means unconstrained.
    /// - Returns: A rendered section when output exists, or `nil` when the section produces no output.
    public func rendered(constrainedTo tokens: Int? = nil) async -> Rendered? {
        guard let content = await renderedContent(constrainedTo: tokens) else {
            return nil
        }
        return Rendered(id: id, role: role, content: content)
    }

    /// Renders only the section's text payload.
    ///
    /// This is a convenience projection over ``renderedContent(constrainedTo:)`` and returns `nil` for
    /// non-text sections such as chat history.
    public func renderText(constrainedTo tokens: Int? = nil) async -> String? {
        await renderedContent(constrainedTo: tokens)?.text
    }

    /// Returns a copy that never renders above the given token budget.
    ///
    /// The returned section preserves identity and metadata while clamping both its estimated token
    /// count and any future render requests to `tokens`.
    public func constrained(to tokens: Int) -> ConcretePromptSection {
        ConcretePromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: min(estimatedTokens, tokens),
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { limit in
                await renderClosure(min(limit ?? tokens, tokens))
            }
        )
    }

    /// Replaces the original renderer with a fixed text summary while preserving section identity.
    ///
    /// The resulting section always renders text content, reports the provided token estimate, and
    /// uses `.keep` compression so the summary is treated as final materialized output.
    public func summarized(_ summary: String, estimatedTokens: Int) -> ConcretePromptSection {
        ConcretePromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: .keep,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { _ in .text(summary) }
        )
    }

    /// Produces a version of the section that renders nothing and consumes no budget.
    ///
    /// The returned section preserves identity and metadata needed for journaling or diffing while
    /// making its rendered output empty.
    public func dropped() -> ConcretePromptSection {
        ConcretePromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: 0,
            compression: .drop,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { _ in nil }
        )
    }
}
