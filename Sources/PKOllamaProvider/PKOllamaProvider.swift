import PKShared

public enum PKOllamaProvider {
    /// Creates an Ollama client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OllamaClient {
        StructuredOutputAdapterRegistry.register(PromptAugmentedJSONSchemaAdapter(), for: .ollama)

        var providerConfig = configuration.activeProviderConfiguration
        if let modelName { providerConfig.modelName = modelName }
        return OllamaClient(
            endpoint: providerConfig.endpoint,
            modelName: providerConfig.modelName,
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }

    /// Creates an Ollama client for a configured model tier.
    public static func makeClient(
        for configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OllamaClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration, modelName: modelName)
    }

    /// Creates an Ollama client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> OllamaClient {
        makeClient(for: configuration)
    }
}
