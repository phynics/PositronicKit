import Foundation
import MonadShared

/// Handles ranking of semantic search results
public struct ContextRanker: Sendable {
    public init() {}

    /// Rank memories based on semantic similarity, tag matches, and time decay
    /// - Parameters:
    ///   - semantic: Initial semantic search results
    ///   - tagBased: Results found via tag matching
    ///   - queryEmbedding: The embedding vector of the query
    /// - Returns: Ranked and combined results
    public func rankMemories(
        semantic: [SemanticSearchResult],
        tagBased: [Memory],
        queryEmbedding: [Double]
    ) -> [SemanticSearchResult] {
        // Tag matches are explicit and highly relevant, give them a significant boost
        // A boost of 0.5 ensures they rank highly but don't strictly override strong semantic matches
        let tagBoost = 0.5

        // Time decay configuration
        // Half-life of 42 days: memories lose half their freshness boost every 42 days
        let halfLifeDays = 42.0
        let now = Date()

        var results: [SemanticSearchResult] = semantic.map {
            SemanticSearchResult(memory: $0.memory, similarity: $0.similarity)
        }

        let existingIds = Set(results.map { $0.memory.id })

        // Boost existing semantic results if they also match tags
        let tagIds = Set(tagBased.map { $0.id })
        results = results.map { res in
            if tagIds.contains(res.memory.id) {
                return SemanticSearchResult(
                    memory: res.memory, similarity: (res.similarity ?? 0) + tagBoost
                )
            }
            return res
        }

        // Add tag results that aren't already included, with boost
        for memory in tagBased where !existingIds.contains(memory.id) {
            let sim = VectorMath.cosineSimilarity(queryEmbedding, memory.embeddingVector)
            results.append(SemanticSearchResult(memory: memory, similarity: sim + tagBoost))
        }

        // Apply time decay to all results
        // Decay formula: decayFactor = 2^(-ageInDays / halfLifeDays)
        // This gives: age=0 -> 1.0, age=42 -> 0.5, age=84 -> 0.25, etc.
        results = results.map { result in
            let ageInDays = now.timeIntervalSince(result.memory.updatedAt) / 86400.0
            let decayFactor = pow(2.0, -ageInDays / halfLifeDays)
            let decayedScore = (result.similarity ?? 0) * decayFactor
            return SemanticSearchResult(memory: result.memory, similarity: decayedScore)
        }

        // Re-sort everything by decayed similarity
        results.sort { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        return results
    }
}
