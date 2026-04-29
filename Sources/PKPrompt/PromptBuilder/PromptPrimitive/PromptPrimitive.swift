//
//  PromptLeaf.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.04.26.
//

import PKShared

// MARK: - Supporting Types

public enum CachePolicy: Sendable, Comparable {
    case stable
    case semiStable
    case volatile
}

public enum CompressionStrategy: Sendable, Equatable {
    case keep
    case truncate(tail: Bool)
    case summarize
    case drop
}

public enum PromptSectionType: Sendable {
    case text
    case list
}

public enum PromptSectionRole: Sendable, Equatable {
    case system
    case context
    case userQuery
    case chatHistory
}

public enum PromptPriority: Int, Sendable {
    case low = 25
    case medium = 50
    case high = 75
    case critical = 100
}

package enum PromptPrimitiveContent: Sendable {
    case text(@Sendable () async -> String?)
    case messages([Message])
}

/// Utility namespace for Primitives
package enum PromptPrimitives {}


// MARK: - PromptPrimitive

/// Prompt primitives render actual prompt content and resolve directly into assembled sections.
package protocol PromptPrimitive: PromptNodeConvertible {
    var id: String { get }
    var role: PromptSectionRole { get }
    var priority: Int { get }
    var estimatedTokens: Int { get }
    var compression: CompressionStrategy { get }
    var type: PromptSectionType { get }
    var cachePolicy: CachePolicy { get }
    var content: PromptPrimitiveContent { get }
    func renderContent() async -> String?
}

package extension PromptPrimitive {
    /// Prompt primitives never expose nested body content.
    var body: EmptyPrompt {
        EmptyPrompt()
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

    var content: PromptPrimitiveContent {
        .text { await renderContent() }
    }

    func makePromptNode() -> PromptNode? {
        let leafContent = content

        return PromptNode(.leaf({ context in
            assembleSections(in: context, content: leafContent)
        }))
    }

    /// Resolves a prompt primitive into a single concrete node with inherited traits applied.
    func assembleSections(in context: PromptAssembly.Context = PromptAssembly.Context()) -> [AssembledPrompt.Section] {
        makePromptNode()?.resolve(in: context) ?? []
    }

    private func assembleSections(
        in context: PromptAssembly.Context,
        content leafContent: PromptPrimitiveContent
    ) -> [AssembledPrompt.Section] {
        let effectivePriority = context.inheritedTraits.priority ?? priority
        let effectiveCompression = context.inheritedTraits.compression ?? compression
        let effectiveCachePolicy = context.inheritedTraits.cachePolicy ?? cachePolicy
        let path = context.ancestorPath + [cachePolicyPathComponent(for: effectiveCachePolicy), id]

        return [
            AssembledPrompt.Section(
                id: id,
                role: role,
                priority: effectivePriority,
                estimatedTokens: estimatedTokens,
                compression: effectiveCompression,
                type: type,
                cachePolicy: effectiveCachePolicy,
                path: path,
                render: { tokens in
                    switch leafContent {
                    case let .text(renderContent):
                        guard let content = await applyRenderConstraint(
                            to: renderContent,
                            tokens: tokens,
                            strategy: effectiveCompression
                        ) else {
                            return nil
                        }
                        return .text(content)

                    case let .messages(messages):
                        guard !messages.isEmpty else {
                            return nil
                        }
                        return .messages(messages)
                    }
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
    
    func estimatedTokenCount(for text: String) -> Int {
        text.isEmpty ? 0 : max(1, text.count / 4)
    }
}
