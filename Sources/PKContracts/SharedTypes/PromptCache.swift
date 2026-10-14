import Foundation

/// Provider-neutral instruction to a model adapter about where a request's reusable prefix
/// boundaries are, how long the provider should retain them, and which cache routing key to use.
///
/// The runtime builds this value; adapters translate it into their native mechanism. A `nil`
/// directive means "no cache hints" and preserves the adapter's default behavior.
public struct PromptCacheDirective: Sendable, Hashable, Codable {
    /// How long a provider should retain a cached prefix.
    ///
    /// The runtime never maps these cases to provider-specific wire values. Adapters own that
    /// translation: for example, the Anthropic adapter maps `.short` to its 5-minute window and
    /// `.extended` to its 1-hour window, while the OpenAI adapter maps them to `in_memory` and
    /// `24h`.
    public enum Retention: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
        /// The provider's short-lived retention window.
        case short
        /// The provider's extended retention window.
        case extended
    }

    /// An opaque, already-hashed routing key that keeps related requests on one provider cache.
    ///
    /// The runtime derives this from a Timeline identity; it is never the raw Timeline id and is
    /// never logged unredacted. `nil` means the request has no Timeline to route on.
    public let routingKey: String?
    /// The requested retention window.
    public let retention: Retention
    /// Ordered prefix boundaries. Adapters honor at most their capability's breakpoint limit.
    public let breakpoints: [PromptCacheBreakpoint]

    /// Creates a cache directive.
    public init(
        routingKey: String? = nil,
        retention: Retention = .short,
        breakpoints: [PromptCacheBreakpoint] = []
    ) {
        self.routingKey = routingKey
        self.retention = retention
        self.breakpoints = breakpoints
    }
}

/// One requested provider-side cache boundary within a request prefix.
public struct PromptCacheBreakpoint: Sendable, Hashable, Codable {
    /// The prompt tier a boundary closes.
    ///
    /// Tiers are ordered the same way the runtime lays out a request: tools, then system tiers,
    /// then history, then the in-Turn tool loop.
    public enum Tier: String, Sendable, Codable, CaseIterable {
        /// The tool definitions block.
        case tools
        /// The stable system tier, which changes only deliberately.
        case stableSystem
        /// The semi-stable system tier, which changes when Agent or Workspace state changes.
        case semiStableSystem
        /// Prior-Turn history.
        case history
        /// The current Turn's tool loop, so each model round reuses the previous round's prefix.
        case toolLoop
    }

    /// Index of the message that closes the tier, or `nil` to mean "end of the tools list".
    public let messageIndex: Int?
    /// The prompt tier this boundary closes.
    public let tier: Tier
    /// The runtime's estimate of the tokens in the prefix ending at this boundary.
    ///
    /// Adapters use this to skip boundaries below a provider's minimum cacheable prefix instead
    /// of wasting a limited breakpoint slot.
    public let estimatedPrefixTokens: Int

    /// Creates a cache breakpoint.
    public init(
        messageIndex: Int? = nil,
        tier: Tier,
        estimatedPrefixTokens: Int
    ) {
        self.messageIndex = messageIndex
        self.tier = tier
        self.estimatedPrefixTokens = estimatedPrefixTokens
    }
}
