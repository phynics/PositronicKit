import Foundation
import PKShared

public enum PKOpenRouterProvider {
    public static func makeClient(configuration: LLMConfiguration) -> OpenRouterClient {
        let providerConfig = configuration.activeProviderConfiguration
        let url = URL(string: providerConfig.endpoint)
        return OpenRouterClient(
            apiKey: providerConfig.apiKey,
            modelName: providerConfig.modelName,
            host: url?.host ?? "openrouter.ai",
            port: url?.port ?? 443,
            scheme: url?.scheme ?? "https",
            timeoutInterval: providerConfig.timeoutInterval,
            maxRetries: providerConfig.maxRetries,
            attribution: .init(
                applicationURL: configuration.providers[.openRouter]?.applicationURL,
                applicationTitle: configuration.providers[.openRouter]?.applicationTitle
            )
        )
    }
}
