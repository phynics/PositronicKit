//
//  PromptPrimitive.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.04.26.
//

import PKShared
import PKUtilities

// MARK: - Supporting Types

/// How stable a section's content is expected to be across turns, used both to bucket
/// sections into the on-disk prompt-journal path (`pathComponent`) and to rank sections
/// during compression.
///
/// Declaration order is significant: `Comparable` conformance is synthesized from it
/// (`stable < semiStable < volatile`), and `StructuredCompressionPlanner` ranks nodes by
/// `cachePolicy` descending — `.volatile` content is preferred to keep over `.stable`
/// content when the compressor has to make room, on the assumption that stable content is
/// unchanging (and so cheaper to regenerate/re-cache) while volatile content is the most
/// contextually relevant right now.
public enum CachePolicy: Sendable, Comparable, Codable {
    /// Content that rarely or never changes between turns (e.g. system instructions).
    case stable
    /// Content that changes occasionally, less often than every turn.
    case semiStable
    /// Content that can change on every turn (e.g. the current user query).
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

/// The end of truncated content that remains in the prompt.
public enum TruncationRetention: Sendable, Equatable, Codable {
    /// Retain content from the beginning and remove content from the end.
    case head
    /// Retain content from the end and remove content from the beginning.
    case tail
}

/// How a section's rendered content should be constrained when it doesn't fit the
/// available token budget. Applied both at primitive render-time (via
/// `applyRenderConstraint`) and by the structured compression planner.
public enum CompressionStrategy: Sendable, Equatable, Codable {
    /// Render the content in full regardless of the token budget.
    case keep
    /// Legacy source-compatible truncation payload; `tail` selects which end is removed
    /// (`true` keeps the head, `false` keeps the tail). Prefer ``truncate(keeping:)`` in new code.
    case truncate(tail: Bool)
    /// Replace the content with a compact summary produced out-of-band by an injected
    /// section compressor (not performed by the render-time constraint itself).
    case summarize
    /// Omit the section's content entirely when it doesn't fit.
    case drop

    /// Creates a truncation strategy that explicitly states which end is retained.
    public static func truncate(keeping retention: TruncationRetention) -> Self {
        .truncate(tail: retention == .head)
    }
}

/// The shape of a rendered prompt section's content.
public enum PromptSectionType: Sendable, Equatable, Codable {
    /// Free-form prose content.
    case text
    /// Content structured as a list (e.g. rendered as bullet points).
    case list
}

/// The functional role a prompt section plays in the assembled conversation, used for
/// grouping/labeling sections (e.g. distinguishing system instructions from chat history).
public enum PromptSectionRole: Sendable, Equatable, Codable {
    /// System-level instructions.
    case system
    /// Ambient/background context supplied to the model.
    case context
    /// The current user query/turn input.
    case userQuery
    /// Prior conversation history.
    case chatHistory
}

/// Relative importance of a prompt section, used to order and weight sections when the
/// compressor decides what to keep, truncate, or drop under a token budget. Higher values
/// are treated as more important; the gaps between values leave room for callers to
/// interpolate custom priorities between the named levels.
public enum PromptPriority: Int, Sendable {
    /// Low-importance content, first to be truncated/dropped under budget pressure.
    case low = 25
    /// Default importance for ordinary content.
    case medium = 50
    /// Above-default importance, preferred over `.medium`/`.low` when trimming.
    case high = 75
    /// Must-keep content, last to be truncated/dropped under budget pressure.
    case critical = 100
}

package enum PromptPrimitiveContent {
    case text(@Sendable () async -> String?)
    case messages([Message])
    case multimodal(MessageContent)
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
        case let .truncate(tail):
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
