import Foundation
import PKShared
import PositronicKit

public enum PKOpenRouterProvider {
    public static func makeLanguageModel(configuration: LLMConfiguration) -> LLMService {
        let url = URL(string: configuration.endpoint)
        let client = OpenRouterClient(
            apiKey: configuration.apiKey,
            modelName: configuration.modelName,
            host: url?.host ?? "openrouter.ai",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries,
            attribution: .init(
                applicationURL: configuration.providers[.openRouter]?.applicationURL,
                applicationTitle: configuration.providers[.openRouter]?.applicationTitle
            )
        )
        StructuredOutputAdapterRegistry.register(NativeJSONSchemaStructuredOutputAdapter(), for: .openRouter)
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
        openRouterKey: String,
        model: String = "openai/gpt-4o",
        endpoint: String = "https://openrouter.ai/api",
        generationParameters: GenerationParameters? = nil,
        applicationURL: String? = nil,
        applicationTitle: String? = nil
    ) {
        let config = LLMConfiguration(
            endpoint: endpoint,
            modelName: model,
            apiKey: openRouterKey,
            provider: .openRouter,
            applicationURL: applicationURL,
            applicationTitle: applicationTitle
        )
        let llm = PKOpenRouterProvider.makeLanguageModel(configuration: config)
        self.init(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory(),
            generationParameters: generationParameters
        ))
    }
}
