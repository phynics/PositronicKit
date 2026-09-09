import Foundation

/// A provider configuration and the client that executes it.
///
/// Provider packages create this value; runtime consumers pass it to the
/// PositronicKit facade without assembling service or client-set implementation
/// details.
public struct ConfiguredLLMProvider: Sendable {
    /// The provider and model settings used by the runtime.
    public let configuration: LLMConfiguration

    /// The client used for model work.
    public let client: any LLMClientProtocol

    /// Creates a configured provider from an explicit configuration and client.
    public init(
        configuration: LLMConfiguration,
        client: any LLMClientProtocol
    ) {
        self.configuration = configuration
        self.client = client
    }
}
