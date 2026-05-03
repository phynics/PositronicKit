import Foundation
import PKShared
import PositronicKit

public enum PKOpenRouterProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { config, components, timeout, retries, model in
            OpenRouterClient(
                apiKey: config.apiKey,
                modelName: model ?? config.modelName,
                host: components.host,
                port: components.port,
                scheme: components.scheme,
                timeoutInterval: timeout,
                maxRetries: retries
            )
        }, for: .openRouter)
    }
}

public extension PositronicKitCore {
    init(
        openRouterKey: String,
        model: String = "openai/gpt-4o",
        endpoint: String = "https://openrouter.ai/api",
        generationParameters: GenerationParameters? = nil
    ) {
        PKOpenRouterProvider.register()
        let config = LLMConfiguration(endpoint: endpoint, modelName: model, apiKey: openRouterKey, provider: .openRouter)
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
