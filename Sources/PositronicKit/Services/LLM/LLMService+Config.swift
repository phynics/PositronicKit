import Foundation
import Logging
import PKShared
import PKUtilities

extension LLMService {
    // MARK: - Internal Configuration Helpers

    /// Update LLM client with configuration
    func updateClient(with config: LLMConfiguration) {
        Logger.module(named: "llm").debug("Updating clients for provider: \(config.activeProvider.rawValue)")

        let clients = Self.makeClients(with: config)
        setClients(main: clients.main, utility: clients.utility, fast: clients.fast)
    }

    /// Static version of client creation for use in init
    static func makeClients(with _: LLMConfiguration) -> (
        main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
        fast: (any LLMClientProtocol)?
    ) {
        return (main: nil, utility: nil, fast: nil)
    }

    /// Parse an endpoint URL into its host, port, and scheme components.
    static func parseEndpoint(_ endpoint: String) -> EndpointComponents {
        let cleanedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanedEndpoint), let host = url.host else {
            Logger.module(named: "llm").error("Invalid endpoint URL: \(endpoint)")
            return EndpointComponents(host: "api.openai.com", port: 443, scheme: "https")
        }

        let scheme = url.scheme ?? "https"
        guard ["http", "https"].contains(scheme.lowercased()) else {
            Logger.module(named: "llm").error("Unsupported scheme: \(scheme)")
            return EndpointComponents(host: "api.openai.com", port: 443, scheme: "https")
        }

        let port: Int
        if let urlPort = url.port {
            port = urlPort
        } else {
            port = (scheme == "https") ? 443 : 80
        }

        return EndpointComponents(host: host, port: port, scheme: scheme)
    }
}
