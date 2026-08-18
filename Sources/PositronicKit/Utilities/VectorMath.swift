import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Shared math utilities for vector operations with platform-specific backends.
public enum VectorMath {
    /// Calculates cosine similarity between two vectors.
    /// - Parameters:
    ///   - firstVector: The first vector.
    ///   - secondVector: The second vector.
    /// - Returns: A finite similarity score from -1.0 to 1.0, or 0.0 for invalid vectors.
    ///
    /// Empty or mismatched vectors, vectors containing NaN or infinity, zero-magnitude
    /// vectors, and non-finite intermediate results use the `0.0` fallback.
    public static func cosineSimilarity(
        between firstVector: [Double],
        and secondVector: [Double]
    ) -> Double {
        #if canImport(Accelerate)
        AccelerateVectorMath.cosineSimilarity(firstVector, secondVector)
        #else
        PortableVectorMath.cosineSimilarity(firstVector, secondVector)
        #endif
    }

    /// Normalize a vector to unit length.
    /// - Parameter vector: Vector to normalize
    /// - Returns: A normalized finite vector. Empty and zero vectors are returned unchanged;
    ///   non-finite inputs and non-finite intermediate results return a zero vector with the
    ///   same length as the input.
    public static func normalize(_ vector: [Double]) -> [Double] {
        #if canImport(Accelerate)
        AccelerateVectorMath.normalize(vector)
        #else
        PortableVectorMath.normalize(vector)
        #endif
    }
}

private enum VectorMathSupport {
    static func containsOnlyFiniteValues(_ vector: [Double]) -> Bool {
        vector.allSatisfy { $0.isFinite }
    }

    static func normalizationFallback(for vector: [Double]) -> [Double] {
        [Double](repeating: 0.0, count: vector.count)
    }

    static func cosineScore(dotProduct: Double, magnitudes: Double) -> Double {
        guard dotProduct.isFinite, magnitudes.isFinite, magnitudes > 0 else { return 0.0 }

        let score = dotProduct / magnitudes
        guard score.isFinite else { return 0.0 }

        return min(max(score, -1.0), 1.0)
    }
}

package enum PortableVectorMath {
    package static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        guard vectorA.count == vectorB.count,
              !vectorA.isEmpty,
              VectorMathSupport.containsOnlyFiniteValues(vectorA),
              VectorMathSupport.containsOnlyFiniteValues(vectorB)
        else { return 0.0 }

        var dotProduct = 0.0
        var sumSqA = 0.0
        var sumSqB = 0.0

        for index in vectorA.indices {
            let a = vectorA[index]
            let b = vectorB[index]
            dotProduct += a * b
            sumSqA += a * a
            sumSqB += b * b
        }

        guard dotProduct.isFinite, sumSqA.isFinite, sumSqB.isFinite else { return 0.0 }

        let magnitudes = Foundation.sqrt(sumSqA) * Foundation.sqrt(sumSqB)
        return VectorMathSupport.cosineScore(dotProduct: dotProduct, magnitudes: magnitudes)
    }

    package static func normalize(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty else { return vector }
        guard VectorMathSupport.containsOnlyFiniteValues(vector) else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        var sumSq = 0.0
        for value in vector {
            sumSq += value * value
        }

        guard sumSq.isFinite else { return VectorMathSupport.normalizationFallback(for: vector) }

        let magnitude = Foundation.sqrt(sumSq)
        guard magnitude.isFinite, magnitude > 0 else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        let result = vector.map { $0 / magnitude }
        guard VectorMathSupport.containsOnlyFiniteValues(result) else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        return result
    }
}

#if canImport(Accelerate)
package enum AccelerateVectorMath {
    package static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        guard vectorA.count == vectorB.count,
              !vectorA.isEmpty,
              VectorMathSupport.containsOnlyFiniteValues(vectorA),
              VectorMathSupport.containsOnlyFiniteValues(vectorB)
        else { return 0.0 }

        var dotProduct: Double = 0.0
        vDSP_dotprD(vectorA, 1, vectorB, 1, &dotProduct, vDSP_Length(vectorA.count))

        var sumSqA: Double = 0.0
        vDSP_svesqD(vectorA, 1, &sumSqA, vDSP_Length(vectorA.count))

        var sumSqB: Double = 0.0
        vDSP_svesqD(vectorB, 1, &sumSqB, vDSP_Length(vectorB.count))

        guard dotProduct.isFinite, sumSqA.isFinite, sumSqB.isFinite else { return 0.0 }

        let magnitudes = Foundation.sqrt(sumSqA) * Foundation.sqrt(sumSqB)
        return VectorMathSupport.cosineScore(dotProduct: dotProduct, magnitudes: magnitudes)
    }

    package static func normalize(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty else { return vector }
        guard VectorMathSupport.containsOnlyFiniteValues(vector) else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        var sumSq: Double = 0.0
        vDSP_svesqD(vector, 1, &sumSq, vDSP_Length(vector.count))

        guard sumSq.isFinite else { return VectorMathSupport.normalizationFallback(for: vector) }

        let magnitude = Foundation.sqrt(sumSq)
        guard magnitude.isFinite, magnitude > 0 else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        var result = [Double](repeating: 0.0, count: vector.count)
        var divisor = magnitude
        vDSP_vsdivD(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))

        guard VectorMathSupport.containsOnlyFiniteValues(result) else {
            return VectorMathSupport.normalizationFallback(for: vector)
        }

        return result
    }
}
#endif
