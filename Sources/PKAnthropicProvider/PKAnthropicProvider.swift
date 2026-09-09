import Foundation
import PKContracts

public enum PKAnthropicProvider: LLMProviderFactory {
    /// Creates a configured Anthropic provider for the common runtime setup path.
    public static func makeConfiguredProvider(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        endpoint: String? = nil
    ) -> ConfiguredLLMProvider {
        var configuration = LLMConfiguration(
            activeProvider: .anthropic,
            providers: [.anthropic: ProviderConfiguration.makeDefault(for: .anthropic)]
        )
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
