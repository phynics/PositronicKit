import Foundation
import Logging
import PKShared
import OpenAI

extension LLMService {
    // MARK: - Internal Configuration Helpers

    /// Update LLM client with configuration
    func updateClient(with config: LLMConfiguration) {
        Logger.module(named: "llm").debug("Updating clients for provider: \(config.provider.rawValue)")

        let clients = Self.makeClients(with: config)
        setClients(main: clients.main, utility: clients.utility, fast: clients.fast)
    }

    /// Static version of client creation for use in init
    static func makeClients(with config: LLMConfiguration) -> (
        main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
        fast: (any LLMClientProtocol)?
    ) {
        let components = parseEndpoint(config.endpoint)
        let timeout = config.timeoutInterval
        let retries = config.maxRetries

        switch config.provider {
        case .ollama:
            return (
                main: makeOllamaClient(config: config, timeout: timeout, retries: retries),
                utility: makeOllamaClient(
                    config: config, timeout: timeout, retries: retries, model: config.utilityModel
                ),
                fast: makeOllamaClient(
                    config: config, timeout: timeout, retries: retries, model: config.fastModel
                )
            )

        case .openRouter:
            return (
                main: makeOpenRouterClient(
                    config: config, components: components, timeout: timeout, retries: retries
                ),
                utility: makeOpenRouterClient(
                    config: config, components: components, timeout: timeout, retries: retries,
                    model: config.utilityModel
                ),
                fast: makeOpenRouterClient(
                    config: config, components: components, timeout: timeout, retries: retries,
                    model: config.fastModel
                )
            )

        case .openAI, .openAICompatible:
            return (
                main: makeOpenAIClient(
                    config: config, components: components, timeout: timeout, retries: retries
                ),
                utility: makeOpenAIClient(
                    config: config, components: components, timeout: timeout, retries: retries,
                    model: config.utilityModel
                ),
                fast: makeOpenAIClient(
                    config: config, components: components, timeout: timeout, retries: retries,
                    model: config.fastModel
                )
            )
        }
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

    // MARK: - Client Factories

    private static func makeOllamaClient(
        config: LLMConfiguration,
        timeout: TimeInterval,
        retries: Int,
        model: String? = nil
    ) -> OllamaClient {
        OllamaClient(
            endpoint: config.endpoint,
            modelName: model ?? config.modelName,
            timeoutInterval: timeout,
            maxRetries: retries
        )
    }

    private static func makeOpenRouterClient(
        config: LLMConfiguration,
        components: EndpointComponents,
        timeout: TimeInterval,
        retries: Int,
        model: String? = nil
    ) -> OpenRouterClient {
        OpenRouterClient(
            apiKey: config.apiKey,
            modelName: model ?? config.modelName,
            host: components.host,
            port: components.port,
            scheme: components.scheme,
            timeoutInterval: timeout,
            maxRetries: retries
        )
    }

    private static func makeOpenAIClient(
        config: LLMConfiguration,
        components: EndpointComponents,
        timeout: TimeInterval,
        retries: Int,
        model: String? = nil
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: config.apiKey,
            modelName: model ?? config.modelName,
            host: components.host,
            port: components.port,
            scheme: components.scheme,
            timeoutInterval: timeout,
            maxRetries: retries
        )
    }
}
