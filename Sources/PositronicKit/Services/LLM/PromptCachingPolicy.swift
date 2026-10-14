import Foundation
import PKContracts
import PKUtilities

/// How the runtime requests provider-side prompt caching.
///
/// The runtime resolves one effective policy per generation: a per-Turn override wins over the
/// runtime default, and ``disabled`` sends no hints. Adapters decide how to translate the
/// resulting `PKContracts.PromptCacheDirective`; the runtime never emits provider wire values.
public enum PromptCachingPolicy: Sendable, Hashable {
    /// Request caching with the given retention window and the runtime's default tier layout.
    case automatic(retention: PromptCacheDirective.Retention = .short)
    /// Send no prompt-cache hints; adapters behave as they did before caching existed.
    case disabled

    /// The retention window to request, or `nil` when caching is disabled.
    public var retention: PromptCacheDirective.Retention? {
        switch self {
        case let .automatic(retention):
            retention
        case .disabled:
            nil
        }
    }

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
