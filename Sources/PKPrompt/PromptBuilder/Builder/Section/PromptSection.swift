import Foundation

/// A validated prompt section with concrete metadata and deferred rendering.
public struct PromptSection: Sendable {
    /// Async renderer used to materialize section content, optionally under a token cap.
    public typealias RenderClosure = @Sendable (Int?) async -> PromptSection.Content?

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
    package let renderClosure: RenderClosure

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

    /// Validates prompt shape and returns sections in canonical assembly order.
    ///
    /// Sections are sorted by cache policy, then priority, while preserving source order as a
    /// final tiebreaker.
    package static func validateAndSort(sections: [PromptSection]) throws -> [PromptSection] {
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw PromptAssemblyError.duplicateSectionIDs(duplicateIDs)
        }

        let userQueryIDs = sections
            .filter { $0.role == .userQuery }
            .map(\.id)
            .sorted()
        guard userQueryIDs.count <= 1 else {
            throw PromptAssemblyError.multipleUserQuerySections(userQueryIDs)
        }

        return sections.enumerated().sorted { lhs, rhs in
            if lhs.element.cachePolicy != rhs.element.cachePolicy {
                return lhs.element.cachePolicy < rhs.element.cachePolicy
            }
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Renders the section content, optionally under a token constraint.
    package func renderedContent(constrainedTo tokens: Int? = nil) async -> PromptSection.Content? {
        await renderClosure(tokens)
    }

    /// Renders the section into an immutable snapshot.
    package func rendered(constrainedTo tokens: Int? = nil) async -> RenderedPrompt.Section? {
        guard let content = await renderedContent(constrainedTo: tokens) else {
            return nil
        }
        return RenderedPrompt.Section(
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
}
