import Foundation
import PKContracts
import PKUtilities

/// Runtime resolution helpers for the provider-neutral `PromptCachingPolicy`.
///
/// The policy value itself lives in `PKContracts` so it can ride on the provider-neutral
/// `PromptCacheReport`. These helpers depend on runtime-only routing-key derivation and stay
/// in the runtime module.
extension PromptCachingPolicy {
    /// The effective policy for a generation: the per-Turn override when present, otherwise the
    /// runtime default.
    static func resolved(
        override: PromptCachingPolicy?,
        default defaultPolicy: PromptCachingPolicy
    ) -> PromptCachingPolicy {
        override ?? defaultPolicy
    }

    /// The cache directive for a request on `timelineID`, or `nil` when caching is disabled.
    ///
    /// The directive carries the Timeline's routing key and the requested retention window. The
    /// tiered breakpoint layout is attached separately so callers without a Timeline (such as
    /// `kit.model` one-shot calls) still get a key-free directive.
    func directive(for timelineID: UUID) -> PromptCacheDirective? {
        guard let retention else { return nil }
        return PromptCacheDirective(
            routingKey: promptCacheRoutingKey(timelineID: timelineID),
            retention: retention
        )
    }

    /// The directive for a caller that has no Timeline, or `nil` when caching is disabled.
    ///
    /// No routing key is attached because there is no Timeline identity to derive one from.
    var keylessDirective: PromptCacheDirective? {
        guard let retention else { return nil }
        return PromptCacheDirective(retention: retention)
    }
}
