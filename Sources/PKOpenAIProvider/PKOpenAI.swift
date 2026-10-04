import Foundation
import PKContracts

/// Entry point for configuring PKRuntime against OpenAI or an OpenAI-compatible endpoint.
public enum PKOpenAI: LLMProviderFactory {
    /// Creates a configured OpenAI provider for the common runtime setup path.
    public static func makeConfiguredProvider(
        apiKey: String,
        model: String = "gpt-4o",
        endpoint: String? = nil
    ) -> ConfiguredLLMProvider {
        var configuration = LLMConfiguration.openAI
        configuration.activeProviderConfiguration.apiKey = apiKey
        configuration.activeProviderConfiguration.modelName = model
        configuration.activeProviderConfiguration.utilityModel = model
        configuration.activeProviderConfiguration.fastModel = model
        if let endpoint {
            configuration.activeProviderConfiguration.endpoint = endpoint
        }
        return ConfiguredLLMProvider(
            configuration: configuration,
            client: makeClient(configuration: configuration)
        )
    }

    /// Creates an OpenAI or OpenAI-compatible client with its structured-output adapter.
    public static func makeClient(
        configuration: LLMConfiguration
    ) -> OpenAIClient {
        let providerConfig = configuration.activeProviderConfiguration
        return OpenAIClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: URL(string: providerConfig.endpoint)?.host ?? "api.openai.com",
            port: URL(string: providerConfig.endpoint)?.port ?? 443,
            scheme: URL(string: providerConfig.endpoint)?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries,
            structuredOutputAdapter: configuration.activeProvider == .openAI
                ? NativeJSONSchemaStructuredOutputAdapter()
                : PromptAugmentedJSONSchemaAdapter()
        )
    }

    /// Creates an embedding client for the OpenAI `/v1/embeddings` endpoint.
    ///
    /// Embedding is a separate capability from chat. The runtime never calls this client; a host
    /// uses it inside its own `AgentContextSource` or `TurnContextSource`.
    public static func makeEmbeddingClient(
        apiKey: String,
        model: String = "text-embedding-3-small",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3
    ) -> OpenAIEmbeddingClient {
        OpenAIEmbeddingClient(
            apiKey: apiKey,
            modelName: model,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries
        )
    }
}
