import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Shared math utilities for vector operations with platform-specific backends.
public enum VectorMath {
    /// Calculate cosine similarity between two vectors
    /// - Parameters:
    ///   - vectorA: First vector
    ///   - vectorB: Second vector
    /// - Returns: Similarity score from -1.0 to 1.0 (0.0 if invalid)
    public static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        #if canImport(Accelerate)
        AccelerateVectorMath.cosineSimilarity(vectorA, vectorB)
        #else
        PortableVectorMath.cosineSimilarity(vectorA, vectorB)
        #endif
    }

    /// Normalize a vector to unit length
    /// - Parameter vector: Vector to normalize
    /// - Returns: Normalized vector
    public static func normalize(_ vector: [Double]) -> [Double] {
        #if canImport(Accelerate)
        AccelerateVectorMath.normalize(vector)
        #else
        PortableVectorMath.normalize(vector)
        #endif
    }
}

package enum PortableVectorMath {
    package static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else { return 0.0 }

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

        let magnitudes = Foundation.sqrt(sumSqA) * Foundation.sqrt(sumSqB)
        guard magnitudes > 0 else { return 0.0 }

        return dotProduct / magnitudes
    }

    package static func normalize(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty else { return vector }

        var sumSq = 0.0
        for value in vector {
            sumSq += value * value
        }

        let magnitude = Foundation.sqrt(sumSq)
        guard magnitude > 0 else { return vector }

        return vector.map { $0 / magnitude }
    }
}

#if canImport(Accelerate)
package enum AccelerateVectorMath {
    package static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else { return 0.0 }

        var dotProduct: Double = 0.0
        vDSP_dotprD(vectorA, 1, vectorB, 1, &dotProduct, vDSP_Length(vectorA.count))

        var sumSqA: Double = 0.0
        vDSP_svesqD(vectorA, 1, &sumSqA, vDSP_Length(vectorA.count))

        var sumSqB: Double = 0.0
        vDSP_svesqD(vectorB, 1, &sumSqB, vDSP_Length(vectorB.count))

        let magnitudes = Foundation.sqrt(sumSqA) * Foundation.sqrt(sumSqB)
        guard magnitudes > 0 else { return 0.0 }

        return dotProduct / magnitudes
    }

    package static func normalize(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty else { return vector }

        var sumSq: Double = 0.0
        vDSP_svesqD(vector, 1, &sumSq, vDSP_Length(vector.count))

        let magnitude = Foundation.sqrt(sumSq)
        guard magnitude > 0 else { return vector }

        var result = [Double](repeating: 0.0, count: vector.count)
        var divisor = magnitude
        vDSP_vsdivD(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))

        return result
    }
}
#endif
