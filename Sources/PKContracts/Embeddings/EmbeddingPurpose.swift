import Foundation

/// Which side of a retrieval pair an embedding input represents.
///
/// Providers that handle queries and documents differently (a task type or an input prefix)
/// map this value; providers whose model is symmetric ignore it.
@_spi(Experimental)
public enum EmbeddingPurpose: String, Sendable, Codable, Equatable {
    case query
    case document
}
