//
//  PromptPrimitive.swift
//  PKRuntime
//
//  Created by Atakan Dulker on 18.04.26.
//

import PKContracts
import PKUtilities

// MARK: - Supporting Types

package enum PromptPrimitiveContent {
    case text(@Sendable () async -> String?)
    case messages([Message])
    case multimodal(MessageContent)
}

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
    var inheritsCachePolicy: Bool { get }
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

    var inheritsCachePolicy: Bool {
        true
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
        let effectiveCachePolicy = inheritsCachePolicy ? (context.inheritedTraits.cachePolicy ?? cachePolicy) : cachePolicy
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

                case let .multimodal(content):
                    guard !content.parts.isEmpty else { return nil }
                    return .multimodal(content)
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
        case let .truncate(retention):
            let charLimit = tokenLimit * 2
            switch retention {
            case .head:
                return String(content.prefix(charLimit)) + "\n... [Truncated]"
            case .tail:
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
