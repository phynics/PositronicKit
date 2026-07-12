import PKShared
import PKUtilities
import PositronicKit
import Foundation
import Logging

/// A mock implementation of VectorStoreProtocol for development and testing
/// when the real USearch library is unavailable or unstable.
public actor MockVectorStore: VectorStoreProtocol {
    private let logger = Logger.module(named: "mock-vector-store")
    private var vectors: [UInt64: [Float]] = [:]

    public init() {}

    public func initialize() async throws {
        logger.info("[MockVectorStore] Initialized")
    }

    public func add(vectors: [[Float]], keys: [UInt64]) async throws {
        guard vectors.count == keys.count else {
            throw VectorStoreError.countMismatch
        }

        for (vector, key) in zip(vectors, keys) {
            self.vectors[key] = vector
        }
        logger.info("[MockVectorStore] Added \(keys.count) vectors")
    }

    public func search(vector: [Float], count: Int) async throws -> [(key: UInt64, distance: Float)] {
        // Simple linear search/sort for mock purposes
        // Calculate cosine similarity or just return random/first ones
        logger.info("[MockVectorStore] Searching with query vector")

        let sorted = vectors.map { key, storedVector in
            let dist = cosineDistance(vector1: vector, vector2: storedVector)
            return (key: key, distance: dist)
        }.sorted { $0.distance < $1.distance }

        return Array(sorted.prefix(count))
    }

    public func save() async throws {
        logger.info("[MockVectorStore] Save called (no-op)")
    }

    public func load() async throws {
        logger.info("[MockVectorStore] Load called (no-op)")
    }

    public var count: Int {
        return vectors.count
    }

    private func cosineDistance(vector1: [Float], vector2: [Float]) -> Float {
        guard vector1.count == vector2.count else { return 1.0 }
        var dot: Float = 0
        var mag1Sq: Float = 0
        var mag2Sq: Float = 0
        for i in 0..<vector1.count {
            let v1 = vector1[i]
            let v2 = vector2[i]
            dot += v1 * v2
            mag1Sq += v1 * v1
            mag2Sq += v2 * v2
        }
        let mag1 = sqrt(mag1Sq)
        let mag2 = sqrt(mag2Sq)
        if mag1 == 0 || mag2 == 0 { return 1.0 }
        return 1.0 - (dot / (mag1 * mag2))
    }
}
