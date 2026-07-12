import Foundation
import PKShared
import PositronicKit

public enum PKAnthropicProvider {
    public static func makeLanguageModel(configuration: LLMConfiguration) -> LLMService {
        let url = URL(string: configuration.endpoint)
        let client = AnthropicClient(
            apiKey: configuration.apiKey,
            modelName: configuration.modelName,
            host: url?.host ?? "api.anthropic.com",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
        StructuredOutputAdapterRegistry.register(AnthropicStructuredOutputAdapter(), for: .anthropic)
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
        anthropicKey: String,
        model: String = "claude-sonnet-4-5",
        endpoint: String = "https://api.anthropic.com",
        generationParameters: GenerationParameters? = nil
    ) {
        let config = LLMConfiguration(
            endpoint: endpoint,
            modelName: model,
            apiKey: anthropicKey,
            provider: .anthropic
        )
        let llm = PKAnthropicProvider.makeLanguageModel(configuration: config)
        self.init(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory(),
            generationParameters: generationParameters
        ))
    }
}
