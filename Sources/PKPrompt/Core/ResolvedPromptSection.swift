import Foundation
import PKShared

/// A fully resolved prompt node with inherited traits applied and a concrete render closure.
public struct ResolvedPromptSection: Sendable {
    public let id: String
    public let role: PromptSectionRole
    public let priority: Int
    public let estimatedTokens: Int
    public let compression: CompressionStrategy
    public let type: PromptSectionType
    public let cachePolicy: CachePolicy
    public let path: [String]
    public let parentID: String?
    public let historyMessages: [Message]?

    /// Stores the final rendering behavior after resolution and any compression constraints.
    private let renderImpl: @Sendable (Int?) async -> String?

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
        historyMessages: [Message]? = nil,
        render: @escaping @Sendable (Int?) async -> String?
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
        self.historyMessages = historyMessages
        self.renderImpl = render
    }

    public func render() async -> String? {
        await renderImpl(nil)
    }

    public func render(constrainedTo tokens: Int?) async -> String? {
        await renderImpl(tokens)
    }

    /// Returns a copy that never renders more than the given token budget.
    public func constrained(to tokens: Int) -> ResolvedPromptSection {
        ResolvedPromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: min(estimatedTokens, tokens),
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { limit in
                await renderImpl(min(limit ?? tokens, tokens))
            }
        )
    }

    /// Replaces the original renderer with a fixed summary while preserving section identity.
    public func summarized(_ summary: String, estimatedTokens: Int) -> ResolvedPromptSection {
        ResolvedPromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: .keep,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { _ in summary }
        )
    }

    /// Produces a version of the section that renders nothing and consumes no budget.
    public func dropped() -> ResolvedPromptSection {
        ResolvedPromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: 0,
            compression: .drop,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { _ in nil }
        )
    }
}
