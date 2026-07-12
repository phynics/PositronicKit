import Foundation
import PKShared
import PKUtilities

public extension PositronicKit {
    /// Generates a response for a single prompt without creating or updating a timeline.
    func complete(_ prompt: String) async throws -> String {
        var text = ""
        for try await chunk in stream(prompt) {
            text += chunk.choices.compactMap { $0.delta.content }.joined()
        }
        return text
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
