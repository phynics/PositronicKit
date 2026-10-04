import Foundation

/// A batch of texts to embed as one provider request.
public struct EmbeddingRequest: Sendable, Equatable {
    /// The texts to embed, in the order the caller wants the embeddings returned.
    public var inputs: [String]

    /// Which side of a retrieval pair the inputs represent.
    public var purpose: EmbeddingPurpose

    /// Optional output dimension truncation (for example OpenAI's `dimensions` parameter).
    /// `nil` uses the model default.
    public var dimensions: Int?

    public init(inputs: [String], purpose: EmbeddingPurpose, dimensions: Int? = nil) {
        self.inputs = inputs
        self.purpose = purpose
        self.dimensions = dimensions
    }
}

/// Token accounting reported by an embedding provider.
public struct EmbeddingUsage: Sendable, Codable, Equatable {
    /// Input tokens consumed by the request.
    public let inputTokens: Int

    public init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }
}

/// The embeddings returned for an ``EmbeddingRequest``.
public struct EmbeddingResponse: Sendable, Equatable {
    /// Embeddings in the same order and count as the request inputs.
    public let embeddings: [Embedding]

    /// Provider token accounting, when the provider reports it.
    public let usage: EmbeddingUsage?

    public init(embeddings: [Embedding], usage: EmbeddingUsage? = nil) {
        self.embeddings = embeddings
        self.usage = usage
    }
}
