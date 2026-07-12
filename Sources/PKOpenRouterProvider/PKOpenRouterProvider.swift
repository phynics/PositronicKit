import Foundation
import PKShared

public enum PKOpenRouterProvider {
    public static func makeClient(configuration: LLMConfiguration) -> OpenRouterClient {
        let url = URL(string: configuration.endpoint)
        return OpenRouterClient(
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
    }
}
