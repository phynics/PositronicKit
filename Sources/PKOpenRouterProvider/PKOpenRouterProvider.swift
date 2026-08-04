import Foundation
import PKShared

public enum PKOpenRouterProvider {
    /// Creates an OpenRouter client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration
    ) -> OpenRouterClient {
        // OpenRouter supports native JSON Schema response formats. Registering
        // this at the provider boundary prevents structured-output callers from
        // silently falling back to a synthetic forced tool call, which some
        // routed models (including `openrouter/free`) may not support.
        StructuredOutputAdapterRegistry.register(
            NativeJSONSchemaStructuredOutputAdapter(),
            for: .openRouter
        )

        let providerConfig = configuration.activeProviderConfiguration
        let url = URL(string: providerConfig.endpoint)
        return OpenRouterClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: url?.host ?? "openrouter.ai",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries,
            attribution: .init(
                applicationURL: configuration.providers[.openRouter]?.applicationURL,
                applicationTitle: configuration.providers[.openRouter]?.applicationTitle
            )
        )
    }

    /// Creates an OpenRouter client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> OpenRouterClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration)
    }
}
