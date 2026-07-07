import Foundation
import PKShared
import PositronicKit

public enum PKAnthropicProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { config, components, timeout, retries, model in
            AnthropicClient(
                apiKey: config.apiKey,
                modelName: model ?? config.modelName,
                host: components.host,
                port: components.port,
                scheme: components.scheme,
                timeoutInterval: timeout,
                maxRetries: retries
            )
        }, for: .anthropic)
        StructuredOutputAdapterRegistry.register(AnthropicStructuredOutputAdapter(), for: .anthropic)
    }
}

public extension PositronicKit {
    init(
        anthropicKey: String,
        model: String = "claude-sonnet-4-5",
        endpoint: String = "https://api.anthropic.com",
        generationParameters: GenerationParameters? = nil
    ) {
        PKAnthropicProvider.register()
        let config = LLMConfiguration(
            endpoint: endpoint,
            modelName: model,
            apiKey: anthropicKey,
            provider: .anthropic
        )
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
