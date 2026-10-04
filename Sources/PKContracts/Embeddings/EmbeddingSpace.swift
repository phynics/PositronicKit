import Foundation

/// The vector space an embedding lives in.
///
/// Two embeddings are comparable only when their spaces are equal. Carrying provider, model,
/// dimension, and normalization in the value prevents vectors from different models being
/// compared silently.
public struct EmbeddingSpace: Sendable, Codable, Hashable {
    /// Stable provider identifier, for example `"openai"`, `"ollama"`, or `"apple-nl"`.
    public let provider: String

    /// The provider model identifier, for example `"text-embedding-3-small"`.
    public let model: String

    /// The number of components in every vector in this space.
    public let dimensions: Int

    /// `true` when the provider returns unit-length vectors.
    public let isNormalized: Bool

    public init(provider: String, model: String, dimensions: Int, isNormalized: Bool) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
        self.isNormalized = isNormalized
    }
}
