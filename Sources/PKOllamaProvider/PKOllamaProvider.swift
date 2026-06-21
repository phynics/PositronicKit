import Foundation
import PKShared
import PositronicKit

public enum PKOllamaProvider {
    public static func register() {
        ExternalLLMProviderRegistry.register(factory: { config, _, timeout, retries, model in
            OllamaClient(
                endpoint: config.endpoint,
                modelName: model ?? config.modelName,
                timeoutInterval: timeout,
                maxRetries: retries
            )
        }, for: .ollama)
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
