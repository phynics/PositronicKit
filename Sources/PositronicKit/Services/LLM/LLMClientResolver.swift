import Foundation
import PKShared

/// Resolves an `LLMConfiguration` into the client set a service dispatches through.
///
/// Concrete resolution policies live at the host composition root (provider modules expose
/// typed `LLMProviderFactory` adapters); the runtime never discovers providers on its own.
public protocol LLMClientResolving: Sendable {
    /// Returns the client set to dispatch through for the given configuration.
    func clients(for configuration: LLMConfiguration) -> LLMClientSet
}

/// A resolution policy that always returns the same client set, independent of configuration.
///
/// Used by explicit `configuration` + `clients` construction and by hosts that own client
/// construction themselves. Use ``LLMClientSet/empty`` to express "no clients".
public struct FixedClientsResolver: LLMClientResolving {
    public let clients: LLMClientSet

    public init(clients: LLMClientSet) {
        self.clients = clients
    }

    public func clients(for configuration: LLMConfiguration) -> LLMClientSet {
        clients
    }

    /// A resolver that never yields any clients.
    public static var empty: FixedClientsResolver {
        FixedClientsResolver(clients: .empty)
    }
}
