import Foundation

/// How the runtime requests provider-side prompt caching.
///
/// The runtime resolves one effective policy per generation: a per-Turn override wins over the
/// runtime default, and ``disabled`` sends no hints. Adapters decide how to translate the
/// resulting ``PromptCacheDirective``; the runtime never emits provider wire values.
///
/// The type lives in `PKContracts` because it is carried on the provider-neutral
/// ``PromptCacheReport`` diagnostic value, which crosses the runtime/contracts boundary.
public enum PromptCachingPolicy: Sendable, Hashable, Codable {
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

    /// Whether caching is requested by this policy.
    public var isEnabled: Bool {
        retention != nil
    }
}
