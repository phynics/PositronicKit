import Foundation
import PKShared

/// A validated prompt section with concrete metadata and deferred rendering.
public struct PromptSection: Sendable {
    /// Async renderer used to materialize section content, optionally under a token cap.
    public typealias RenderClosure = @Sendable (Int?) async -> PromptSectionContent?

    /// Stable section identifier.
    public let id: String

    /// Semantic role used by downstream projections.
    public let role: PromptSectionRole

    /// Effective prompt ordering priority.
    public let priority: Int

    /// Estimated token count before any further constrained rendering.
    public let estimatedTokens: Int

    /// Requested compression strategy for this section.
    public let compression: CompressionStrategy

    /// Concrete section type.
    public let type: PromptSectionType

    /// Cache policy inherited by this section.
    public let cachePolicy: CachePolicy

    /// Canonical node path for this section.
    public let path: [String]

    /// Stable parent section identifier when present.
    public let parentID: String?

    /// Compression details captured during assembly.
    public let compressionOutcome: CompressionNodeReport?
    private let renderClosure: RenderClosure

    /// Creates a concrete prompt section with deferred rendering.
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
        compressionOutcome: CompressionNodeReport? = nil,
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
        self.compressionOutcome = compressionOutcome
        self.renderClosure = render
    }

    /// Renders the section content, optionally under a token constraint.
    public func renderedContent(constrainedTo tokens: Int? = nil) async -> PromptSectionContent? {
        await renderClosure(tokens)
    }

    /// Renders the section into an immutable snapshot.
    public func rendered(constrainedTo tokens: Int? = nil) async -> RenderedPromptSection? {
        guard let content = await renderedContent(constrainedTo: tokens) else {
            return nil
        }
        return RenderedPromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome,
            content: content
        )
    }

    /// Renders the section and extracts only its plain-text content.
    public func renderText(constrainedTo tokens: Int? = nil) async -> String? {
        await renderedContent(constrainedTo: tokens)?.text
    }

    /// Returns a constrained copy that never renders beyond the supplied token limit.
    public func constrained(to tokens: Int, compressionOutcome: CompressionNodeReport? = nil) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: min(estimatedTokens, tokens),
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { limit in
                await renderClosure(min(limit ?? tokens, tokens))
            }
        )
    }

    /// Returns a summarized text copy of this section.
    public func summarized(
        _ summary: String,
        estimatedTokens: Int,
        compressionOutcome: CompressionNodeReport? = nil
    ) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { _ in .text(summary) }
        )
    }

    /// Returns a dropped copy of this section that renders no content.
    public func dropped(compressionOutcome: CompressionNodeReport? = nil) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: 0,
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome ?? self.compressionOutcome,
            render: { _ in nil }
        )
    }

    /// Returns a copy with updated compression metadata.
    public func withCompressionOutcome(_ compressionOutcome: CompressionNodeReport?) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            compressionOutcome: compressionOutcome,
            render: renderClosure
        )
    }
}
