import Foundation
import PKShared
import PKUtilities
import PositronicKit

public enum PKOllamaProvider {
    public static func makeLanguageModel(configuration: LLMConfiguration) -> LLMService {
        let client = OllamaClient(
            endpoint: configuration.endpoint,
            modelName: configuration.modelName,
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
        StructuredOutputAdapterRegistry.register(OllamaStructuredOutputAdapter(), for: .ollama)
        return LLMService(
            storage: InMemoryConfigurationService(config: configuration),
            client: client,
            utilityClient: client,
            fastClient: client
        )
    }
}

public extension PositronicKit {
    convenience init(
        ollamaModel: String,
        endpoint: String = "http://localhost:11434",
        generationParameters: GenerationParameters? = nil
    ) {
        let config = LLMConfiguration(endpoint: endpoint, modelName: ollamaModel, provider: .ollama)
        let llm = PKOllamaProvider.makeLanguageModel(configuration: config)
        self.init(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory(),
            generationParameters: generationParameters
        ))
    }
}
