import Foundation

/// A per-model-round diagnostic describing what prefix the runtime expected to be cached,
/// what the provider reported, and why any prefix reset happened.
///
/// A report is produced after each model round's usage arrives. `resets` is empty when the
/// reusable prefix carried over from the previous round; otherwise it names every tier or
/// condition that invalidated part of the prefix.
public struct PromptCacheReport: Sendable, Hashable, Codable {
    /// Why a prefix was not reusable from the previous model round.
    public enum ResetReason: String, Sendable, Codable, CaseIterable {
        /// There was no previous round for this Turn, so nothing could be reused.
        case firstRound
        /// The tool catalog changed since the previous round.
        case toolsChanged
        /// A stable-tier section changed.
        case stableTierChanged
        /// A semi-stable-tier section changed.
        case semiStableSegmentChanged
        /// Stepwise history trimming dropped messages, moving the history boundary.
        case historyTrim
        /// The host-provided history projection changed.
        case historyProjectionChanged
        /// The effective policy disabled caching, so no prefix was requested.
        case cachingDisabled
        /// The adapter reported that the provider does not support prompt caching.
        case providerUnsupported
    }

    /// The Turn this report belongs to.
    public let turnID: UUID
    /// The 1-based model round within the Turn.
    public let modelRoundIndex: Int
    /// The effective caching policy for this round.
    public let policy: PromptCachingPolicy
    /// The breakpoints sent with the request, after any adapter capping.
    public let breakpoints: [PromptCacheBreakpoint]
    /// Estimated tokens in the prefix that is identical to the previous round.
    public let expectedReusableTokens: Int
    /// Cached-read tokens reported by the provider, when it reports them.
    public let reportedCachedTokens: Int?
    /// Cache-write tokens reported by the provider, when it reports them.
    public let reportedCacheWriteTokens: Int?
    /// Why the prefix was not fully reusable. Empty means the prefix was preserved.
    public let resets: [ResetReason]

    public init(
        turnID: UUID,
        modelRoundIndex: Int,
        policy: PromptCachingPolicy,
        breakpoints: [PromptCacheBreakpoint],
        expectedReusableTokens: Int,
        reportedCachedTokens: Int? = nil,
        reportedCacheWriteTokens: Int? = nil,
        resets: [ResetReason] = []
    ) {
        self.turnID = turnID
        self.modelRoundIndex = modelRoundIndex
        self.policy = policy
        self.breakpoints = breakpoints
        self.expectedReusableTokens = expectedReusableTokens
        self.reportedCachedTokens = reportedCachedTokens
        self.reportedCacheWriteTokens = reportedCacheWriteTokens
        self.resets = resets
    }
}
