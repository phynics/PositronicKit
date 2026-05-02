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

    package var pathComponent: String {
        switch self {
        case .stable:
            return "stable"
        case .semiStable:
            return "semiStable"
        case .volatile:
            return "volatile"
        }
    }
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

/// Prompt primitives render actual prompt content and lower to leaf prompt nodes.
package protocol PromptPrimitive: Prompt {
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
        PromptNode(.leaf(self))
    }

    /// Materializes a primitive leaf into a concrete section with inherited traits applied.
    func makeSection(in context: PromptBuildContext = PromptBuildContext()) -> PromptSection {
        let effectivePriority = context.inheritedTraits.priority ?? priority
        let effectiveCompression = context.inheritedTraits.compression ?? compression
        let effectiveCachePolicy = context.inheritedTraits.cachePolicy ?? cachePolicy
        let path = context.ancestorPath + [effectiveCachePolicy.pathComponent, id]
        let leafContent = content

        return PromptSection(
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
        )
    }

    /// Applies truncation constraints after rendering when a token limit is provided.
    private func applyRenderConstraint(
        to renderContent: @escaping @Sendable () async -> String?,
        tokens tokenLimit: Int?,
        strategy: CompressionStrategy
    ) async -> String? {
        guard let content = await renderContent(), !content.isEmpty else {
            return nil
        }

        guard let tokenLimit else {
            return content
        }
        assert(tokenLimit > 0)

        let tokenEstimate = TokenEstimator.estimate(text: content)
        guard tokenEstimate > tokenLimit else {
            return content
        }

        switch strategy {
        case .keep:
            return content
        case .truncate(let tail):
            let charLimit = tokenLimit * 2
            if tail {
                return String(content.prefix(charLimit)) + "\n... [Truncated]"
            } else {
                return "... [Truncated]\n" + String(content.suffix(charLimit))
            }
        case .summarize:
            // Summaries are produced by TokenBudget/StructuredCompressionExecutor via
            // an injected SectionCompressor, not during primitive render-time constraints.
            return content
        case .drop:
            return nil
        }
    }

}
