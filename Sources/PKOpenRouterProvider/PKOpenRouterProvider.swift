import Foundation
import PKContracts

public enum PKOpenRouterProvider: LLMProviderFactory {
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
