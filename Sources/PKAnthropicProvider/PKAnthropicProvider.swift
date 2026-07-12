import Foundation
import PKShared

public enum PKAnthropicProvider {
    public static func makeClient(configuration: LLMConfiguration) -> AnthropicClient {
        let url = URL(string: configuration.endpoint)
        return AnthropicClient(
            apiKey: configuration.apiKey,
            modelName: configuration.modelName,
            host: url?.host ?? "api.anthropic.com",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
    }
}
