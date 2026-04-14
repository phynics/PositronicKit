import ErrorKit
import PKShared
import Foundation

public enum VectorStoreError: PKError {
    case countMismatch
    case dimensionMismatch
    case initializationFailed(String)

    public var errorDomain: String { PKErrorDomain.vector }

    public var errorCode: Int {
        switch self {
        case .countMismatch: return 7001
        case .dimensionMismatch: return 7002
        case .initializationFailed: return 7003
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .countMismatch, .dimensionMismatch:
            return "A data inconsistency was detected in the vector store."
        case let .initializationFailed(reason):
            return "Failed to initialize the vector store: \(reason)"
        }
    }
}

public protocol VectorStoreProtocol: Actor, Sendable {
    /// Initialize the vector store index
    func initialize() async throws

    /// Add vectors to the store
    /// - Parameters:
    ///   - vectors: Array of Float arrays representing vectors
    ///   - keys: Corresponding keys for the vectors
    func add(vectors: [[Float]], keys: [UInt64]) async throws

    /// Search for nearest neighbors
    /// - Parameters:
    ///   - vector: Query vector
    ///   - count: Number of results to return
    /// - Returns: Array of (key, distance) tuples
    func search(vector: [Float], count: Int) async throws -> [(key: UInt64, distance: Float)]

    /// Save the index to disk
    func save() async throws

    /// Load the index from disk
    func load() async throws

    /// Get the number of vectors in the index
    var count: Int { get async }
}
