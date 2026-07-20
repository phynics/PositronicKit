import PKShared

public enum PKOllamaProvider {
    public static func makeClient(configuration: LLMConfiguration) -> OllamaClient {
        StructuredOutputAdapterRegistry.register(OllamaStructuredOutputAdapter(), for: .ollama)

        let providerConfig = configuration.activeProviderConfiguration
        return OllamaClient(
            endpoint: providerConfig.endpoint,
            modelName: providerConfig.modelName,
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }
}
