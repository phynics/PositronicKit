import Foundation
import PKShared
import PositronicKit

public enum PKOpenRouterProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { request in
            let attribution = OpenRouterClient.Attribution(
                applicationURL: request.config.providers[.openRouter]?.applicationURL,
                applicationTitle: request.config.providers[.openRouter]?.applicationTitle
            )
            return OpenRouterClient(
                apiKey: request.config.apiKey,
                modelName: request.model ?? request.config.modelName,
                host: request.components.host,
                port: request.components.port,
                scheme: request.components.scheme,
                timeoutInterval: request.timeout,
                maxRetries: request.retries,
                attribution: attribution
            )
        }, for: .openRouter)
        StructuredOutputAdapterRegistry.register(NativeJSONSchemaStructuredOutputAdapter(), for: .openRouter)
    }
}

public extension PositronicKit {
    convenience init(
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
        self.init(configuration: .init(
            provider: .init(llmService: llm),
            persistence: .inMemory(),
            generationParameters: generationParameters
        ))
    }
}
