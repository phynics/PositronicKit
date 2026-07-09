import Foundation
import PKShared
import PositronicKit

public enum PKOllamaProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { request in
            OllamaClient(
                endpoint: request.config.endpoint,
                modelName: request.model ?? request.config.modelName,
                timeoutInterval: request.timeout,
                maxRetries: request.retries
            )
        }, for: .ollama)
        StructuredOutputAdapterRegistry.register(OllamaStructuredOutputAdapter(), for: .ollama)
    }
}

public extension PositronicKit {
    init(
        ollamaModel: String,
        endpoint: String = "http://localhost:11434",
        generationParameters: GenerationParameters? = nil
    ) {
        PKOllamaProvider.register()
        let config = LLMConfiguration(endpoint: endpoint, modelName: ollamaModel, provider: .ollama)
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
