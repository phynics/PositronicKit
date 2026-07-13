import Foundation
import PKShared

public enum PKOpenAIProvider {
    public static func makeClient(configuration: LLMConfiguration) -> OpenAIClient {
        OpenAIClient(
            apiKey: configuration.apiKey,
            modelName: configuration.modelName,
            host: URL(string: configuration.endpoint)?.host ?? "api.openai.com",
            port: URL(string: configuration.endpoint)?.port ?? 443,
            scheme: URL(string: configuration.endpoint)?.scheme ?? "https",
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
    }
}
