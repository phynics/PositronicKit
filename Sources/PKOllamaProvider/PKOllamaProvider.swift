import PKContracts

/// Entry point for configuring PositronicKit against a local or remote Ollama server.
public enum PKOllamaProvider: LLMProviderFactory {
    /// Creates a configured Ollama provider for the common runtime setup path.
    public static func makeConfiguredProvider(
        model: String = "llama3",
        endpoint: String? = nil
    ) -> ConfiguredLLMProvider {
        var configuration = LLMConfiguration(
            activeProvider: .ollama,
            providers: [.ollama: ProviderConfiguration.makeDefault(for: .ollama)]
        )
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

    /// Creates an Ollama client with its structured-output adapter.
    public static func makeClient(
        configuration: LLMConfiguration
    ) -> OllamaClient {
        let providerConfig = configuration.activeProviderConfiguration
        return OllamaClient(
            endpoint: providerConfig.endpoint,
            modelName: providerConfig.modelName,
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }
}
