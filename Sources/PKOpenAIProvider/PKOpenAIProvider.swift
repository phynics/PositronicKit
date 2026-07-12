import Foundation
import PKShared
import PositronicKit

public enum PKOpenAIProvider {
    public static func makeLanguageModel(configuration: LLMConfiguration) -> LLMService {
        let client = OpenAIClient(
            apiKey: configuration.apiKey,
            modelName: configuration.modelName,
            host: URL(string: configuration.endpoint)?.host ?? "api.openai.com",
            port: URL(string: configuration.endpoint)?.port ?? 443,
            scheme: URL(string: configuration.endpoint)?.scheme ?? "https",
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
        StructuredOutputAdapterRegistry.register(
            configuration.provider == .openAI ? NativeJSONSchemaStructuredOutputAdapter() : OpenAICompatibleStructuredOutputAdapter(),
            for: configuration.provider
        )
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
        openAIKey: String,
        model: String = "gpt-4o",
        generationParameters: GenerationParameters? = nil
    ) {
        let config = LLMConfiguration(modelName: model, apiKey: openAIKey, provider: .openAI)
        let llm = PKOpenAIProvider.makeLanguageModel(configuration: config)
        self.init(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory(),
            generationParameters: generationParameters
        ))
    }
}
