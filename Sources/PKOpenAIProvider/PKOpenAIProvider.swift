import Foundation
import PKContracts

public enum PKOpenAIProvider: LLMProviderFactory {
    /// Creates an OpenAI or OpenAI-compatible client with its structured-output adapter.
    public static func makeClient(
        configuration: LLMConfiguration
    ) -> OpenAIClient {
        let providerConfig = configuration.activeProviderConfiguration
        return OpenAIClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: URL(string: providerConfig.endpoint)?.host ?? "api.openai.com",
            port: URL(string: providerConfig.endpoint)?.port ?? 443,
            scheme: URL(string: providerConfig.endpoint)?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries,
            structuredOutputAdapter: configuration.activeProvider == .openAI
                ? NativeJSONSchemaStructuredOutputAdapter()
                : PromptAugmentedJSONSchemaAdapter()
        )
    }
}
