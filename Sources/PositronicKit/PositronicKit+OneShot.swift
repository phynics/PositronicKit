import Foundation
import PKShared
import PKUtilities

public extension PositronicKit {
    /// Generates a response for a single prompt without creating or updating a timeline.
    func complete(_ prompt: String) async throws -> String {
        var text = ""
        do {
            for try await chunk in stream(prompt) {
                text += chunk.choices.compactMap { $0.delta.content }.joined()
            }
        } catch {
            throw wrapForeignError(error)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let provider = await languageModel.configuration.activeProvider
            throw LLMServiceError.emptyResponse(provider: provider.rawValue)
        }
        return text
    }

    /// Generates a structured response for a single prompt without creating or
    /// updating a timeline. The returned string is the raw structured payload
    /// (JSON), decodable via `StructuredOutputDecoder`.
    ///
    /// Structured output is threaded through the same provider adapter path as the
    /// full chat pipeline (`StructuredOutputExecution`): the request is translated into
    /// either a native `responseFormat` or a synthetic forced tool call, and — for the
    /// synthetic-tool path — the underlying stream's tool-call argument deltas are
    /// rewritten into content deltas before being assembled here, so callers always see
    /// a plain JSON string regardless of how the provider actually returned it.
    func complete(_ prompt: String, structuredOutput: StructuredOutputRequest) async throws -> String {
        try await languageModel.sendStructuredMessage(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: defaultGenerationParameters,
            modelTier: .primary
        )
    }

    /// Streams a response for a single prompt without creating or updating a timeline.
    func stream(_ prompt: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await languageModel.chatStream(
                    messages: [LLMMessage(role: .user, content: prompt)],
                    tools: nil,
                    toolChoice: nil,
                    responseFormat: nil,
                    generationParameters: defaultGenerationParameters,
                    modelTier: .primary
                )
                do {
                    for try await chunk in stream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: wrapForeignError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
