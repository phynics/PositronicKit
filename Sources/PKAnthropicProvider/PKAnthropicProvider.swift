import Foundation
import PKShared

public enum PKAnthropicProvider: LLMProviderFactory {
    /// Creates an Anthropic client with its structured-output adapter.
    public static func makeClient(
        configuration: LLMConfiguration
    ) -> AnthropicClient {
        let providerConfig = configuration.activeProviderConfiguration
        let url = URL(string: providerConfig.endpoint)
        return AnthropicClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: url?.host ?? "api.anthropic.com",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries
        )
    }
}
