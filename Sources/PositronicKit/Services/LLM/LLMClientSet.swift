import Foundation
import PKContracts

/// The resolved model-tier clients a service dispatches through.
///
/// Replaces the three independent optional client properties on `LLMService`. Tier
/// selection and fallback rules live here so every path (send, stream, structured-output
/// adapters, health) resolves clients identically.
public struct LLMClientSet: Sendable {
    public var primary: (any LLMClientProtocol)?
    public var utility: (any LLMClientProtocol)?
    public var fast: (any LLMClientProtocol)?

    public init(
        primary: (any LLMClientProtocol)?,
        utility: (any LLMClientProtocol)? = nil,
        fast: (any LLMClientProtocol)? = nil
    ) {
        self.primary = primary
        self.utility = utility
        self.fast = fast
    }

    /// Resolves the client for a model tier, applying the documented fallback rules.
    ///
    /// `.utility` and `.fast` fall back to `primary` when their dedicated client is not
    /// configured; `.primary` never substitutes another tier.
    public func client(for tier: ModelTier) -> (any LLMClientProtocol)? {
        switch tier {
        case .primary:
            return primary
        case .utility:
            return utility ?? primary
        case .fast:
            return fast ?? primary
        }
    }

    /// A client set with no clients configured.
    public static var empty: LLMClientSet {
        LLMClientSet(primary: nil)
    }
}
