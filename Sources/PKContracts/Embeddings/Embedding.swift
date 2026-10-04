import Foundation

/// One embedding vector together with the space it belongs to.
///
/// The space travels with the vector so a comparison between embeddings from different models
/// fails loudly instead of returning a meaningless score.
public struct Embedding: Sendable, Codable, Equatable {
    /// The vector components.
    public let vector: [Float]

    /// The vector space this embedding belongs to.
    public let space: EmbeddingSpace

    public init(vector: [Float], space: EmbeddingSpace) {
        self.vector = vector
        self.space = space
    }

    /// Cosine similarity between this embedding and `other`.
    ///
    /// - Returns: A score from `-1` to `1`. A zero-magnitude vector, an empty vector, or a
    ///   non-finite magnitude yields `0`.
    /// - Throws: ``EmbeddingError/incompatibleSpaces(_:_:)`` when the two spaces differ.
    public func cosineSimilarity(to other: Embedding) throws -> Float {
        guard space == other.space else {
            throw EmbeddingError.incompatibleSpaces(space, other.space)
        }

        guard vector.count == other.vector.count, !vector.isEmpty else {
            return 0
        }

        var dotProduct: Float = 0
        var sumOfSquaresSelf: Float = 0
        var sumOfSquaresOther: Float = 0
        for index in vector.indices {
            let selfValue = vector[index]
            let otherValue = other.vector[index]
            dotProduct += selfValue * otherValue
            sumOfSquaresSelf += selfValue * selfValue
            sumOfSquaresOther += otherValue * otherValue
        }

        guard dotProduct.isFinite, sumOfSquaresSelf.isFinite, sumOfSquaresOther.isFinite else {
            return 0
        }

        let magnitude = sumOfSquaresSelf.squareRoot() * sumOfSquaresOther.squareRoot()
        guard magnitude.isFinite, magnitude > 0 else {
            return 0
        }

        let score = dotProduct / magnitude
        guard score.isFinite else {
            return 0
        }

        return min(max(score, -1), 1)
    }
}
