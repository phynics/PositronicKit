import MonadShared
import Foundation

/// Result of a semantic search including the memory and its similarity score
public struct SemanticSearchResult: Sendable, Codable, Equatable {
    public let memory: Memory
    public let similarity: Double?

    public init(memory: Memory, similarity: Double? = nil) {
        self.memory = memory
        self.similarity = similarity
    }
}
