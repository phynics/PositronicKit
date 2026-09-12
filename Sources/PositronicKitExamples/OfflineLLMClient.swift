import PKContracts
import PositronicKit

/// A deterministic model used by the executable example.
///
/// It exercises the full Thread and Turn path without credentials or network access. Provider
/// integrations remain covered by their own examples and tests.
struct OfflineLLMClient: LLMStreamClient {
    private static let exampleConfiguration: LLMConfiguration = {
        var provider = ProviderConfiguration.makeDefault(for: .ollama)
        provider.endpoint = "http://offline.example"
        provider.modelName = "positronickit-example"
        provider.utilityModel = provider.modelName
        provider.fastModel = provider.modelName
        return LLMConfiguration(activeProvider: .ollama, providers: [.ollama: provider])
    }()

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { Self.exampleConfiguration }
    }

    func generationStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        guard !responseModalities.contains(.audio), audioOutput == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MultimodalContentError.missingCapability(.audioOutput))
            }
        }
        let responseParts = ["PositronicKit ", "is running ", "offline."]
        return AsyncThrowingStream { continuation in
            for (index, content) in responseParts.enumerated() {
                continuation.yield(LLMStreamChunk(
                    id: "positronickit-example",
                    model: Self.exampleConfiguration.activeProviderConfiguration.modelName,
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(
                            role: index == 0 ? .assistant : nil,
                            content: content
                        ),
                        finishReason: index == responseParts.index(before: responseParts.endIndex) ? "stop" : nil
                    )]
                ))
            }
            continuation.finish()
        }
    }
}
