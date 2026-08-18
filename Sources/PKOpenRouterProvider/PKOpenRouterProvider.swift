import Foundation
import PKShared

public enum PKOpenRouterProvider {
    /// Creates an OpenRouter client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OpenRouterClient {
        // OpenRouter supports native JSON Schema response formats. Registering
        // this at the provider boundary prevents structured-output callers from
        // silently falling back to a synthetic forced tool call, which some
        // routed models (including `openrouter/free`) may not support.
        StructuredOutputAdapterRegistry.register(
            NativeJSONSchemaStructuredOutputAdapter(),
            for: .openRouter
        )

        var providerConfig = configuration.activeProviderConfiguration
        if let modelName { providerConfig.modelName = modelName }
        let baseURL = OpenRouterClient.validatedBaseURL(from: providerConfig.endpoint)
        return OpenRouterClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            baseURL: baseURL,
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries,
            attribution: .init(
                applicationURL: configuration.providers[.openRouter]?.applicationURL,
                applicationTitle: configuration.providers[.openRouter]?.applicationTitle
            )
        )
    }

    /// Creates an OpenRouter client for a configured model tier.
    public static func makeClient(
        for configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OpenRouterClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration, modelName: modelName)
    }

    /// Creates an OpenRouter client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> OpenRouterClient {
        makeClient(for: configuration)
    }
}
