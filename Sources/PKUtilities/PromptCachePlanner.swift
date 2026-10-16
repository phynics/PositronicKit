import Foundation
import PKContracts

/// One resolved prompt-cache breakpoint after an adapter applies its breakpoint cap and
/// minimum-prefix-token filter.
package struct PromptCachePlan: Sendable, Equatable {
    /// The retention window the provider should use.
    package let retention: PromptCacheDirective.Retention
    /// The opaque routing key to send to the provider, when the runtime derived one.
    package let routingKey: String?
    /// Breakpoints that survived capping and minimum-prefix filtering, ordered by request
    /// position (tools first, then message order).
    package let breakpoints: [PromptCacheBreakpoint]

    package init(
        retention: PromptCacheDirective.Retention,
        routingKey: String?,
        breakpoints: [PromptCacheBreakpoint]
    ) {
        self.retention = retention
        self.routingKey = routingKey
        self.breakpoints = breakpoints
    }
}

/// Provider-neutral breakpoint planning shared by the adapters.
///
/// The runtime emits a directive ordered by position but does not know a provider's breakpoint
/// cap or minimum cacheable prefix. This planner turns the directive into the breakpoints an
/// adapter should actually send: it drops redundant tiers, filters prefixes below the provider's
/// minimum, and caps the result at the provider's limit. The adapter owns the provider-native
/// translation (for example, `cache_control` on Anthropic blocks or `prompt_cache_key` on
/// OpenAI).
package enum PromptCachePlanner {
    /// The breakpoint tiers ordered by how much value they add to a cache hit, highest first.
    ///
    /// When a directive exceeds the provider's cap, the planner drops the lowest-value tiers
    /// first. `toolLoop` is the most valuable boundary within a tool round, and `history` is the
    /// most valuable boundary across rounds; the issue's ordering rule that `semiStableSystem`
    /// drops before `history` is encoded here.
    private static let valueOrder: [PromptCacheBreakpoint.Tier] = [
        .toolLoop,
        .history,
        .stableSystem,
        .tools,
        .semiStableSystem,
    ]

    /// The position of a tier within a request prefix, used to order the plan.
    private static let positionOrder: [PromptCacheBreakpoint.Tier: Int] = [
        .tools: 0,
        .stableSystem: 1,
        .semiStableSystem: 2,
        .history: 3,
        .toolLoop: 4,
    ]

    /// Plans the breakpoints an adapter should send.
    ///
    /// - Parameters:
    ///   - directive: The runtime's provider-neutral cache directive.
    ///   - maxBreakpoints: The adapter's maximum breakpoints per request.
    ///   - minimumPrefixTokens: The provider's minimum cacheable prefix for this model. A
    ///     breakpoint whose prefix is below it is dropped, so a limited slot is not wasted on a
    ///     prefix the provider will not cache.
    /// - Returns: The surviving breakpoints in request order.
    package static func plan(
        _ directive: PromptCacheDirective,
        maxBreakpoints: Int,
        minimumPrefixTokens: Int = 0
    ) -> PromptCachePlan {
        // One breakpoint per tier: a directive from a host-rendered array can repeat a tier, and
        // only the furthest boundary of a tier matters for the prefix.
        var furthestByTier: [PromptCacheBreakpoint.Tier: PromptCacheBreakpoint] = [:]
        for breakpoint in directive.breakpoints {
            guard breakpoint.estimatedPrefixTokens >= minimumPrefixTokens else { continue }
            if let existing = furthestByTier[breakpoint.tier] {
                if sortKey(breakpoint) > sortKey(existing) {
                    furthestByTier[breakpoint.tier] = breakpoint
                }
            } else {
                furthestByTier[breakpoint.tier] = breakpoint
            }
        }

        var surviving = Array(furthestByTier.values)
        // Drop from the least valuable tier until the provider cap is met.
        for tier in valueOrder.reversed() where surviving.count > maxBreakpoints {
            surviving.removeAll { $0.tier == tier }
        }
        surviving.sort { sortKey($0) < sortKey($1) }

        return PromptCachePlan(
            retention: directive.retention,
            routingKey: directive.routingKey,
            breakpoints: surviving
        )
    }

    private static func sortKey(_ breakpoint: PromptCacheBreakpoint) -> PromptCacheSortKey {
        PromptCacheSortKey(
            position: positionOrder[breakpoint.tier] ?? Int.max,
            messageIndex: breakpoint.messageIndex ?? -1
        )
    }

    /// A total order over breakpoints: tools first, then message order, then tier position.
    private struct PromptCacheSortKey: Comparable {
        let position: Int
        let messageIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.messageIndex != rhs.messageIndex { return lhs.messageIndex < rhs.messageIndex }
            return lhs.position < rhs.position
        }
    }
}

/// Anthropic-compatible `cache_control` marker shared by the Anthropic adapter and the
/// Anthropic-routed OpenRouter path.
package struct PromptCacheControl: Codable, Equatable, Sendable {
    package let type: String
    package let ttl: String?

    package init(ttl: String? = nil) {
        type = "ephemeral"
        self.ttl = ttl
    }

    /// The marker for a directive retention window.
    ///
    /// `.short` uses the provider default (5 minutes) by omitting `ttl`; `.extended` requests
    /// the 1-hour window. Because one directive carries a single retention, every breakpoint in
    /// a request shares a TTL, so the provider's "longer TTL before shorter TTL" ordering rule
    /// holds by construction.
    package static func marker(for retention: PromptCacheDirective.Retention) -> PromptCacheControl {
        switch retention {
        case .short: PromptCacheControl()
        case .extended: PromptCacheControl(ttl: "1h")
        }
    }
}

/// Provider-specific prompt-cache defaults shared by the adapters that route to the same upstream.
package enum PromptCacheProviderDefaults {
    /// Anthropic's minimum cacheable prefix for a model, in tokens.
    ///
    /// Anthropic's documented minimums range from 512 to 4,096 tokens across the model family.
    /// The adapter maps the current families conservatively: Haiku models require 2,048 tokens;
    /// every other Claude model requires 1,024. Shared so the OpenRouter adapter applies the same
    /// threshold for `anthropic/*` models.
    package static func anthropicMinimumPrefixTokens(for model: String) -> Int {
        model.localizedCaseInsensitiveContains("haiku") ? 2048 : 1024
    }
}
