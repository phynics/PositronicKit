import Foundation

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
public enum TruncationRetention: String, Sendable, Equatable, Codable {
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
    /// Truncate the content to the budget, retaining the given end.
    case truncate(keeping: TruncationRetention)
    /// Replace the content with a compact summary produced out-of-band by an injected
    /// section compressor (not performed by the render-time constraint itself).
    case summarize
    /// Omit the section's content entirely when it doesn't fit.
    case drop
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
