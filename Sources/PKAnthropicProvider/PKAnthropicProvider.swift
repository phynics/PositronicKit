import Foundation
import PKShared

public enum PKAnthropicProvider {
    /// Creates an Anthropic client and registers its structured-output adapter globally.
    public static func makeClientAndRegisterStructuredOutputAdapter(
        configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> AnthropicClient {
        StructuredOutputAdapterRegistry.register(DefaultStructuredOutputAdapter(), for: .anthropic)

        var providerConfig = configuration.activeProviderConfiguration
        if let modelName { providerConfig.modelName = modelName }
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

    /// Creates an Anthropic client for a configured model tier.
    public static func makeClient(
        for configuration: LLMConfiguration,
        modelName: String? = nil
    ) -> AnthropicClient {
        makeClientAndRegisterStructuredOutputAdapter(configuration: configuration, modelName: modelName)
    }

    /// Creates an Anthropic client and registers its structured-output adapter globally.
    @available(*, deprecated, renamed: "makeClientAndRegisterStructuredOutputAdapter(configuration:)")
    public static func makeClient(configuration: LLMConfiguration) -> AnthropicClient {
        makeClient(for: configuration)
    }
}
