import Foundation
import PKShared
import PositronicKit

public enum PKOpenRouterProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { config, components, timeout, retries, model in
            let attribution = OpenRouterClient.Attribution(
                applicationURL: config.providers[.openRouter]?.applicationURL,
                applicationTitle: config.providers[.openRouter]?.applicationTitle
            )
            return OpenRouterClient(
                apiKey: config.apiKey,
                modelName: model ?? config.modelName,
                host: components.host,
                port: components.port,
                scheme: components.scheme,
                timeoutInterval: timeout,
                maxRetries: retries,
                attribution: attribution
            )
        }, for: .openRouter)
        StructuredOutputAdapterRegistry.register(NativeJSONSchemaStructuredOutputAdapter(), for: .openRouter)
    }
}

public extension PositronicKit {
    init(
        openRouterKey: String,
        model: String = "openai/gpt-4o",
        endpoint: String = "https://openrouter.ai/api",
        generationParameters: GenerationParameters? = nil,
        applicationURL: String? = nil,
        applicationTitle: String? = nil
    ) {
        PKOpenRouterProvider.register()
        let config = LLMConfiguration(
            endpoint: endpoint,
            modelName: model,
            apiKey: openRouterKey,
            provider: .openRouter,
            applicationURL: applicationURL,
            applicationTitle: applicationTitle
        )
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
