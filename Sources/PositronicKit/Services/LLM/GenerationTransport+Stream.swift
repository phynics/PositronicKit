import Foundation
import PKContracts

/// The single runtime adapter that maps a ``GenerationTransport`` onto the streaming
/// `LLMStreamClient` seam.
///
/// `.streaming` forwards to `generationStream(...)`. `.requestResponse` awaits
/// `generationCompletion(...)`, yields the one terminal chunk, and finishes. Both cases
/// return the same `AsyncThrowingStream<LLMStreamChunk, Error>`, so callers never branch on
/// transport and no second execution path exists.
extension LLMStreamClient {
    func generation(
        transport: GenerationTransport,
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        switch transport {
        case .streaming:
            return await generationStream(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                modelTier: modelTier,
                responseModalities: responseModalities,
                audioOutput: audioOutput
            )
        case .requestResponse:
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let chunk = try await generationCompletion(
                            messages: messages,
                            tools: tools,
                            toolChoice: toolChoice,
                            responseFormat: responseFormat,
                            generationParameters: generationParameters,
                            modelTier: modelTier,
                            responseModalities: responseModalities,
                            audioOutput: audioOutput
                        )
                        if Task.isCancelled { throw CancellationError() }
                        continuation.yield(chunk)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                // Cancelling the consuming stream cancels the in-flight provider call. This
                // mirrors `ModelInferenceCapability.streamChunks` and keeps request-response
                // Turns cancellable exactly like streaming Turns.
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}
