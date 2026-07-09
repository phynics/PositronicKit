import Foundation
import PKShared
import PositronicKit

public enum PKAnthropicProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { request in
            AnthropicClient(
                apiKey: request.config.apiKey,
                modelName: request.model ?? request.config.modelName,
                host: request.components.host,
                port: request.components.port,
                scheme: request.components.scheme,
                timeoutInterval: request.timeout,
                maxRetries: request.retries
            )
        }, for: .anthropic)
        StructuredOutputAdapterRegistry.register(AnthropicStructuredOutputAdapter(), for: .anthropic)
    }
}

public extension PositronicKit {
    convenience init(
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
