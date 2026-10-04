import Foundation

/// A runtime-neutral client that turns text into embeddings.
///
/// The protocol is deliberately separate from `LLMClientProtocol`: chat-only providers must not
/// stub an embedding method. The runtime never calls an embedding client. Hosts use one inside
/// their own `AgentContextSource` or `TurnContextSource` implementation.
public protocol EmbeddingClientProtocol: Sendable {
    /// Largest request this client accepts. Larger requests are rejected before any I/O.
    var inputBudget: EmbeddingInputBudget { get }

    /// Embeds every input in `request` and returns the embeddings in input order.
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse
}

public extension EmbeddingClientProtocol {
    /// Embeds one query text.
    func embedQuery(_ text: String) async throws -> Embedding {
        let response = try await embed(EmbeddingRequest(inputs: [text], purpose: .query))
        guard response.embeddings.count == 1 else {
            throw EmbeddingError.responseCountMismatch(expected: 1, actual: response.embeddings.count)
        }
        return response.embeddings[0]
    }

    /// Embeds document texts, splitting them into budget-sized batches and concatenating the
    /// results in input order.
    func embedDocuments(_ texts: [String]) async throws -> [Embedding] {
        var embeddings: [Embedding] = []
        for batch in try inputBudget.batches(texts) {
            let response = try await embed(EmbeddingRequest(inputs: batch, purpose: .document))
            guard response.embeddings.count == batch.count else {
                throw EmbeddingError.responseCountMismatch(expected: batch.count, actual: response.embeddings.count)
            }
            embeddings.append(contentsOf: response.embeddings)
        }
        return embeddings
    }
}
