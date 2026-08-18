import PKShared

public enum PKOllamaProvider: LLMProviderFactory {
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
