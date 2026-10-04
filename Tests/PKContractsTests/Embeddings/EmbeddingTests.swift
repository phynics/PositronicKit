import Foundation
import PKContracts
import Testing

@Suite("Embedding")
struct EmbeddingTests {
    private let space = EmbeddingSpace(
        provider: "test",
        model: "test-model",
        dimensions: 3,
        isNormalized: true
    )

    @Test("Cosine similarity matches a known orthogonal pair")
    func cosineSimilarityKnownPair() throws {
        let first = Embedding(vector: [1, 0, 0], space: space)
        let second = Embedding(vector: [0, 1, 0], space: space)
        #expect(try first.cosineSimilarity(to: second) == 0)
    }

    @Test("Cosine similarity of identical vectors is one")
    func cosineSimilarityIdentical() throws {
        let first = Embedding(vector: [1, 2, 3], space: space)
        let second = Embedding(vector: [1, 2, 3], space: space)
        #expect(abs(try first.cosineSimilarity(to: second) - 1) < 1e-5)
    }

    @Test("Cosine similarity of opposite vectors is minus one")
    func cosineSimilarityOpposite() throws {
        let first = Embedding(vector: [1, 0], space: EmbeddingSpace(provider: "t", model: "m", dimensions: 2, isNormalized: true))
        let second = Embedding(vector: [-1, 0], space: EmbeddingSpace(provider: "t", model: "m", dimensions: 2, isNormalized: true))
        #expect(try first.cosineSimilarity(to: second) == -1)
    }

    @Test("Comparing embeddings from different spaces throws incompatibleSpaces")
    func incompatibleSpacesThrow() {
        let first = Embedding(vector: [1, 0], space: space)
        let second = Embedding(
            vector: [1, 0],
            space: EmbeddingSpace(provider: "other", model: "other-model", dimensions: 2, isNormalized: false)
        )
        #expect(throws: EmbeddingError.incompatibleSpaces(first.space, second.space)) {
            try first.cosineSimilarity(to: second)
        }
    }

    @Test("A same-space dimension difference still throws instead of comparing silently")
    func sameSpaceDifferentDimensionsThrow() {
        let wideSpace = EmbeddingSpace(provider: "t", model: "m", dimensions: 3, isNormalized: true)
        let narrowSpace = EmbeddingSpace(provider: "t", model: "m", dimensions: 2, isNormalized: true)
        let first = Embedding(vector: [1, 0, 0], space: wideSpace)
        let second = Embedding(vector: [1, 0], space: narrowSpace)
        #expect(throws: EmbeddingError.incompatibleSpaces(wideSpace, narrowSpace)) {
            try first.cosineSimilarity(to: second)
        }
    }

    @Test("Zero-magnitude vectors score zero")
    func zeroVectorsScoreZero() throws {
        let first = Embedding(vector: [0, 0], space: space)
        let second = Embedding(vector: [1, 2], space: space)
        #expect(try first.cosineSimilarity(to: second) == 0)
    }

    @Test("Embedding and EmbeddingSpace decode from their published JSON shape")
    func codableGoldenDecode() throws {
        let json = Data(#"""
        {
          "vector": [0.5, -0.25, 0.125],
          "space": {
            "provider": "openai",
            "model": "text-embedding-3-small",
            "dimensions": 3,
            "isNormalized": true
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(Embedding.self, from: json)
        #expect(decoded.vector == [0.5, -0.25, 0.125])
        #expect(decoded.space == EmbeddingSpace(
            provider: "openai",
            model: "text-embedding-3-small",
            dimensions: 3,
            isNormalized: true
        ))

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let spaceObject = try #require(object["space"] as? [String: Any])
        #expect(spaceObject["provider"] as? String == "openai")
        #expect(spaceObject["dimensions"] as? Int == 3)
        #expect(spaceObject["isNormalized"] as? Bool == true)
    }
}
