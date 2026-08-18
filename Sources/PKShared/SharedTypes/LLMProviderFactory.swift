/// A compile-time factory for a concrete provider client.
///
/// Provider modules conform their public factory type to this protocol. The protocol does not
/// register or discover providers at runtime; hosts select the concrete factory they want to use.
public protocol LLMProviderFactory: Sendable {
    associatedtype Client: LLMClientProtocol

    /// Creates a client from the configuration for the provider being constructed.
    static func makeClient(configuration: LLMConfiguration) -> Client
}
