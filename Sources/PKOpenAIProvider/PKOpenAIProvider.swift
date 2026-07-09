import Foundation
import PKShared
import PositronicKit

public enum PKOpenAIProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { request in
            OpenAIClient(
                apiKey: request.config.apiKey,
                modelName: request.model ?? request.config.modelName,
                host: request.components.host,
                port: request.components.port,
                scheme: request.components.scheme,
                timeoutInterval: request.timeout,
                maxRetries: request.retries
            )
        }, for: .openAI)
        StructuredOutputAdapterRegistry.register(NativeJSONSchemaStructuredOutputAdapter(), for: .openAI)

        ExternalLLMProviderRegistry.register(factory: { request in
            OpenAIClient(
                apiKey: request.config.apiKey,
                modelName: request.model ?? request.config.modelName,
                host: request.components.host,
                port: request.components.port,
                scheme: request.components.scheme,
                timeoutInterval: request.timeout,
                maxRetries: request.retries
            )
        }, for: .openAICompatible)
        StructuredOutputAdapterRegistry.register(OpenAICompatibleStructuredOutputAdapter(), for: .openAICompatible)
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
