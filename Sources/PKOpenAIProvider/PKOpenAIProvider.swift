import Foundation
import PKShared
import PositronicKit

public enum PKOpenAIProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { config, components, timeout, retries, model in
            OpenAIClient(
                apiKey: config.apiKey,
                modelName: model ?? config.modelName,
                host: components.host,
                port: components.port,
                scheme: components.scheme,
                timeoutInterval: timeout,
                maxRetries: retries
            )
        }, for: .openAI)

        ExternalLLMProviderRegistry.register(factory: { config, components, timeout, retries, model in
            OpenAIClient(
                apiKey: config.apiKey,
                modelName: model ?? config.modelName,
                host: components.host,
                port: components.port,
                scheme: components.scheme,
                timeoutInterval: timeout,
                maxRetries: retries
            )
        }, for: .openAICompatible)
    }
}

public extension PositronicKit {
    init(
        openAIKey: String,
        model: String = "gpt-4o",
        generationParameters: GenerationParameters? = nil
    ) {
        PKOpenAIProvider.register()
        let config = LLMConfiguration(modelName: model, apiKey: openAIKey, provider: .openAI)
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
