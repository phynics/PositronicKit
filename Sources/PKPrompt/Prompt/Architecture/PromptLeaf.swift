//
//  PromptLeaf.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.04.26.
//

import PKShared

/// Prompt leaves render actual prompt content and resolve directly into concrete nodes.
public protocol PromptLeaf: PromptComposite {
    var id: String { get }
    var role: PromptSectionRole { get }
    var priority: Int { get }
    var estimatedTokens: Int { get }
    var compression: CompressionStrategy { get }
    var type: PromptSectionType { get }
    var cachePolicy: CachePolicy { get }
    var historyMessages: [Message]? { get }
    func renderContent() async -> String?
}

public extension PromptLeaf {
    /// Prompt leaves never expose nested body content.
    var body: NeverSection {
        NeverSection()
    }

    /// Leaves identify themselves through `id`, not an extra path component.
    var sectionPathComponent: String? {
        nil
    }

    var role: PromptSectionRole {
        .context
    }

    var compression: CompressionStrategy {
        .keep
    }

    var type: PromptSectionType {
        .text
    }

    var cachePolicy: CachePolicy {
        .volatile
    }

    var historyMessages: [Message]? {
        nil
    }

    func render(constrainedTo tokens: Int?) async -> String? {
        await resolve(in: PromptResolutionContext()).first?.render(constrainedTo: tokens)
    }

    /// Resolves a prompt leaf into a single concrete node with inherited traits applied.
    func resolve(in context: PromptResolutionContext = PromptResolutionContext()) -> [ResolvedPromptSection] {
        let effectivePriority = context.inheritedPriority ?? priority
        let effectiveCompression = context.inheritedCompression ?? compression
        let effectiveCachePolicy = context.inheritedCachePolicy ?? cachePolicy
        let path = context.ancestorPath + [cachePolicyPathComponent(for: effectiveCachePolicy), id]

        return [
            ResolvedPromptSection(
                id: id,
                role: role,
                priority: effectivePriority,
                estimatedTokens: estimatedTokens,
                compression: effectiveCompression,
                type: type,
                cachePolicy: effectiveCachePolicy,
                path: path,
                historyMessages: historyMessages,
                render: { tokens in
                    await applyRenderConstraint(
                        to: renderContent,
                        tokens: tokens,
                        strategy: effectiveCompression
                    )
                }
            ),
        ]
    }

    /// Applies truncation constraints after rendering when a token limit is provided.
    private func applyRenderConstraint(
        to renderContent: @escaping @Sendable () async -> String?,
        tokens: Int?,
        strategy: CompressionStrategy
    ) async -> String? {
        guard let tokens else {
            return await renderContent()
        }

        guard let content = await renderContent(), !content.isEmpty else {
            return nil
        }

        let estimated = max(1, content.count / 4)
        guard estimated > tokens else {
            return content
        }

        guard case let .truncate(tail) = strategy else {
            return content
        }

        let charLimit = max(0, tokens * 4)
        guard charLimit > 0 else {
            return nil
        }

        if tail {
            return String(content.prefix(charLimit)) + "\n... [Truncated]"
        }

        return "... [Truncated]\n" + String(content.suffix(charLimit))
    }

    /// Cache policy participates in the stable path used by downstream hashing and journaling.
    private func cachePolicyPathComponent(for policy: CachePolicy) -> String {
        switch policy {
        case .stable:
            return "stable"
        case .semiStable:
            return "semiStable"
        case .volatile:
            return "volatile"
        }
    }
}
