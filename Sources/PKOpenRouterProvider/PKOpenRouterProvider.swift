import Foundation
import PKContracts

/// Entry point for configuring PositronicKit against the OpenRouter multi-provider API.
public enum PKOpenRouterProvider: LLMProviderFactory {
    /// Creates a configured OpenRouter provider for the common runtime setup path.
    public static func makeConfiguredProvider(
        apiKey: String,
        model: String = "openai/gpt-4o",
        endpoint: String? = nil
    ) -> ConfiguredLLMProvider {
        var configuration = LLMConfiguration.openRouter
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

    /// Creates an OpenRouter client with its structured-output adapter.
    public static func makeClient(
        configuration: LLMConfiguration
    ) -> OpenRouterClient {
        let providerConfig = configuration.activeProviderConfiguration
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
}
