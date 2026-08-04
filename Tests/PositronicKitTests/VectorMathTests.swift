import Foundation
import Testing
@testable import PositronicKit

@Suite("Vector math portability")
struct VectorMathTests {
    @Test("Portable cosine similarity handles empty and mismatched vectors")
    func portableCosineSimilarityRejectsInvalidShapes() {
        #expect(PortableVectorMath.cosineSimilarity([], []) == 0.0)
        #expect(PortableVectorMath.cosineSimilarity([1.0], [1.0, 2.0]) == 0.0)
    }

    @Test("Portable cosine similarity handles zero, negative, and ordinary values")
    func portableCosineSimilarityHandlesCoreCases() {
        #expect(PortableVectorMath.cosineSimilarity([0.0, 0.0], [1.0, 2.0]) == 0.0)
        #expect(PortableVectorMath.cosineSimilarity([1.0, 0.0], [1.0, 0.0]) == 1.0)
        #expect(PortableVectorMath.cosineSimilarity([1.0, 0.0], [-1.0, 0.0]) == -1.0)
    }

    @Test("Portable normalization preserves empty and zero vectors")
    func portableNormalizationHandlesDegenerateCases() {
        #expect(PortableVectorMath.normalize([]) == [])
        #expect(PortableVectorMath.normalize([0.0, 0.0]) == [0.0, 0.0])
    }

    @Test("Portable normalization produces unit vectors")
    func portableNormalizationProducesUnitVectors() {
        let normalized = PortableVectorMath.normalize([3.0, 4.0])
        #expect(abs(normalized[0] - 0.6) < 0.000_001)
        #expect(abs(normalized[1] - 0.8) < 0.000_001)
    }

    @Test("Portable backend matches public API for larger vectors")
    func portableBackendMatchesPublicAPI() {
        let vectorA = Array(1...512).map(Double.init)
        let vectorB = Array(1...512).reversed().map(Double.init)

        let portable = PortableVectorMath.cosineSimilarity(vectorA, vectorB)
        let dispatched = VectorMath.cosineSimilarity(vectorA, vectorB)

        #expect(abs(portable - dispatched) < 0.000_000_1)
    }

    @Test("Labeled cosine similarity preserves the positional API result")
    func labeledCosineSimilarityMatchesCompatibilityOverload() {
        let vectorA = [1.0, 2.0, 3.0]
        let vectorB = [3.0, 2.0, 1.0]

        #expect(
            VectorMath.cosineSimilarity(between: vectorA, and: vectorB)
                == VectorMath.cosineSimilarity(vectorA, vectorB)
        )
    }

    #if canImport(Accelerate)
    @Test("Accelerate and portable backends stay numerically aligned")
    func accelerateAndPortableBackendsAgree() {
        let vectorA = Array(1...1_024).map { Double($0) / 10.0 }
        let vectorB = Array(1...1_024).map { Double(1_025 - $0) / 20.0 }

        let portableCosine = PortableVectorMath.cosineSimilarity(vectorA, vectorB)
        let accelerateCosine = AccelerateVectorMath.cosineSimilarity(vectorA, vectorB)
        #expect(abs(portableCosine - accelerateCosine) < 0.000_000_1)

        let portableNormalized = PortableVectorMath.normalize(vectorA)
        let accelerateNormalized = AccelerateVectorMath.normalize(vectorA)
        #expect(portableNormalized.count == accelerateNormalized.count)
        for index in portableNormalized.indices {
            #expect(abs(portableNormalized[index] - accelerateNormalized[index]) < 0.000_000_1)
        }
    }
    #endif
}
