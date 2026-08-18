import Foundation
import PKShared

/// Resolves an `LLMConfiguration` into the client set the service dispatches through.
///
/// Concrete factories live at the host composition root (provider modules expose typed
/// `LLMProviderFactory` adapters); the runtime never discovers providers on its own.
public protocol LLMClientResolving: Sendable {
    func clients(for configuration: LLMConfiguration) -> LLMClientSet
}

/// A resolver that always returns a fixed client set, independent of the configuration.
///
/// Used by explicit `configuration` + `clients` construction, where the host owns client
/// construction and expects the supplied clients to keep routing.
struct FixedClientsResolver: LLMClientResolving {
    let clients: LLMClientSet

    func clients(for configuration: LLMConfiguration) -> LLMClientSet {
        clients
    }
}

/// Adapts the legacy `@Sendable (LLMConfiguration) -> (main:utility:fast:)` factory closure
/// to `LLMClientResolving` so existing composition code keeps working unchanged.
struct ClosureClientResolver: LLMClientResolving {
    let factory: (@Sendable (LLMConfiguration) -> (
        main: (any LLMClientProtocol)?,
        utility: (any LLMClientProtocol)?,
        fast: (any LLMClientProtocol)?
    ))?

    func clients(for configuration: LLMConfiguration) -> LLMClientSet {
        guard let factory else { return .empty }
        let clients = factory(configuration)
        return LLMClientSet(
            primary: clients.main,
            utility: clients.utility,
            fast: clients.fast
        )
    }
}
