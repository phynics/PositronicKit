import Foundation
import PKContracts
import PKUtilities

/// Builds the runtime's internal tiered prompt layout from an assembled prompt artifact.
///
/// The builder is the single translation point between the shared section model and the
/// runtime's provider-facing layout. Tier assignment mirrors the assembled section's role and
/// cache policy so later tiered-wire work (#277) can group segments without re-deriving them.
enum PromptLayoutBuilder {
    static func build(from prompt: RenderedPrompt) -> PromptLayout {
        PromptLayout(
            segments: prompt.sections.map(segment(for:)),
            string: prompt.string,
            sectionsByID: prompt.sectionsByID
        )
    }

    static func segment(for section: RenderedPrompt.Section) -> LayoutSegment {
        LayoutSegment(
            id: section.id,
            role: section.role,
            tier: tier(for: section),
            content: content(for: section.content),
            estimatedTokens: section.estimatedTokens
        )
    }

    static func tier(for section: RenderedPrompt.Section) -> PromptCacheTier {
        switch section.role {
        case .chatHistory:
            return .history
        case .userQuery:
            return .query
        case .system, .context:
            switch section.cachePolicy {
            case .stable:
                return .stable
            case .semiStable:
                return .semiStable
            case .volatile:
                return .volatile
            }
        }
    }

    static func content(for content: PromptSection.Content) -> PromptLayoutContent {
        switch content {
        case let .text(text):
            return .text(MessageContent(text))
        case let .messages(messages):
            return .messages(messages)
        case let .multimodal(content):
            return .text(content)
        }
    }
}
