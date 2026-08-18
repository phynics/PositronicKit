import Foundation
import PKShared

public enum PKOpenAIProvider {
    /// Creates an OpenAI client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OpenAIClient {
        StructuredOutputAdapterRegistry.register(
            configuration.activeProvider == .openAI
                ? NativeJSONSchemaStructuredOutputAdapter()
                : PromptAugmentedJSONSchemaAdapter(),
            for: configuration.activeProvider
        )

        var providerConfig = configuration.activeProviderConfiguration
        if let modelName { providerConfig.modelName = modelName }
        return OpenAIClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: URL(string: providerConfig.endpoint)?.host ?? "api.openai.com",
            port: URL(string: providerConfig.endpoint)?.port ?? 443,
            scheme: URL(string: providerConfig.endpoint)?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }

    /// Creates an OpenAI client for a configured model tier.
    public static func makeClient(
        for configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> OpenAIClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration, modelName: modelName)
    }

    /// Creates an OpenAI client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> OpenAIClient {
        makeClient(for: configuration)
    }
}
