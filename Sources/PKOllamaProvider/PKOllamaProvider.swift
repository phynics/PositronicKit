import PKShared

public enum PKOllamaProvider {
    /// Creates an Ollama client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration
    ) -> OllamaClient {
        StructuredOutputAdapterRegistry.register(PromptAugmentedJSONSchemaAdapter(), for: .ollama)

        let providerConfig = configuration.activeProviderConfiguration
        return OllamaClient(
            endpoint: providerConfig.endpoint,
            modelName: providerConfig.modelName,
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }

    /// Creates an Ollama client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> OllamaClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration)
    }
}
