import PKShared

public enum PKOllamaProvider {
    public static func makeClient(configuration: LLMConfiguration) -> OllamaClient {
        OllamaClient(
            endpoint: configuration.endpoint,
            modelName: configuration.modelName,
            timeoutInterval: configuration.timeoutInterval,
            maxRetries: configuration.maxRetries
        )
    }
}
