import Dependencies
import ErrorKit
import Foundation
import Logging
import MonadPrompt
import MonadShared

/// Pipeline stage responsible for retrieving relevant semantic memories and tags.
public struct MemoryRetrievalStage: PipelineStage {
    @Dependency(\.memoryStore) var memoryStore
    @Dependency(\.embeddingService) var embeddingService

    private let logger = Logger.module(named: "com.monad.MemoryRetrievalStage")
    private let ranker = ContextRanker()

    /// Initializes a new memory retrieval stage.
    public init() {}

    /// Retrieves relevant memories and tags for the query in the context.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields progress events as retrieval proceeds.
    public func process(
        _ context: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        let query = context.query
        let augmentedQuery = await context.augmentedQuery
        let limit = context.limit
        let tagGenerator = context.tagGenerator

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let results = try await fetchRelevantMemories(
                        for: query,
                        tagContext: augmentedQuery,
                        limit: limit,
                        tagGenerator: tagGenerator,
                        onProgress: { progress in
                            continuation.yield(.progress(progress))
                        }
                    )
                    await context.setResults(
                        memories: results.memories,
                        tags: results.tags,
                        vector: results.vector,
                        semanticResults: results.semanticResults,
                        tagResults: results.tagResults
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Fetches all memories, tags, and embeddings required for the query.
    /// - Parameters:
    ///   - query: The raw user query.
    ///   - tagContext: The augmented query context for tag generation.
    ///   - limit: Result limit for retrieval.
    ///   - tagGenerator: Optional closure for generating tags.
    ///   - onProgress: Closure to report gathering progress.
    /// - Returns: A tuple containing the gathered results.
    private func fetchRelevantMemories(
        for query: String,
        tagContext: String,
        limit: Int,
        tagGenerator: (@Sendable (String) async throws -> [String])?,
        onProgress: (@Sendable (Message.ContextGatheringProgress) -> Void)?
    ) async throws -> (memories: [SemanticSearchResult], tags: [String], vector: [Double], semanticResults: [SemanticSearchResult], tagResults: [Memory]) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (memories: [], tags: [], vector: [], semanticResults: [], tagResults: [])
        }

        let tags = await generateTagsSafely(tagContext: tagContext, tagGenerator: tagGenerator, onProgress: onProgress)
        let embedding = try await generateQueryEmbedding(for: query, onProgress: onProgress)

        if Task.isCancelled {
            return (memories: [], tags: [], vector: [], semanticResults: [], tagResults: [])
        }

        let doubleEmbedding = embedding.map { Double($0) }
        let (semanticResults, tagResults) = try await performParallelSearch(
            embedding: doubleEmbedding, tags: tags, limit: limit, onProgress: onProgress
        )

        onProgress?(.ranking)
        let finalResults = ranker.rankMemories(
            semantic: semanticResults, tagBased: tagResults, queryEmbedding: doubleEmbedding
        )
        let topResults = Array(finalResults.prefix(limit))

        // swiftlint:disable:next line_length
        logger.info("Recall: \(topResults.count) memories selected from \(semanticResults.count) semantic + \(tagResults.count) tag matches")

        return (
            memories: topResults, tags: tags, vector: doubleEmbedding,
            semanticResults: semanticResults, tagResults: tagResults
        )
    }

    /// Attempts to generate tags from the context while suppressing non-critical errors.
    /// - Parameters:
    ///   - tagContext: Context for tag generation.
    ///   - tagGenerator: Optional tag generation closure.
    ///   - onProgress: Progress reporting callback.
    /// - Returns: An array of generated tags, or empty if generation fails.
    private func generateTagsSafely(
        tagContext: String,
        tagGenerator: (@Sendable (String) async throws -> [String])?,
        onProgress: (@Sendable (Message.ContextGatheringProgress) -> Void)?
    ) async -> [String] {
        guard let generator = tagGenerator else { return [] }
        onProgress?(.tagging)
        do {
            let tags = try await generator(tagContext)
            logger.debug("Generated tags: \(tags)")
            return tags
        } catch {
            logger.warning("Optional tag generation failed: \(ErrorKit.userFriendlyMessage(for: error))")
            return []
        }
    }

    /// Generates the query embedding vector and reports progress.
    /// - Parameters:
    ///   - query: The query string to embed.
    ///   - onProgress: Progress reporting callback.
    /// - Returns: The embedding vector.
    /// - Throws: `ContextManagerError.embeddingFailed` if generation fails.
    private func generateQueryEmbedding(
        for query: String,
        onProgress: (@Sendable (Message.ContextGatheringProgress) -> Void)?
    ) async throws -> [Float] {
        onProgress?(.embedding)
        do {
            return try await embeddingService.generateEmbedding(for: query)
        } catch {
            throw ContextManagerError.embeddingFailed(error)
        }
    }

    /// Searches both semantic and tag-based memory stores in parallel.
    /// - Parameters:
    ///   - embedding: The embedding vector for the search.
    ///   - tags: The tags for filtering.
    ///   - limit: Max number of results.
    ///   - onProgress: Progress reporting callback.
    /// - Returns: A tuple with the raw search results.
    /// - Throws: `ContextManagerError.persistenceFailed` if retrieval fails.
    private func performParallelSearch(
        embedding: [Double],
        tags: [String],
        limit: Int,
        onProgress: (@Sendable (Message.ContextGatheringProgress) -> Void)?
    ) async throws -> ([SemanticSearchResult], [Memory]) {
        onProgress?(.searching)

        do {
            async let semanticTask = memoryStore.searchMemories(
                embedding: embedding,
                limit: limit * 2,
                minSimilarity: 0.35
            )
            async let tagTask = memoryStore.searchMemories(matchingAnyTag: tags)

            let (rawSemanticResults, tagResults) = try await (semanticTask, tagTask)
            let semanticResults = rawSemanticResults.map {
                SemanticSearchResult(memory: $0.memory, similarity: $0.similarity)
            }
            return (semanticResults, tagResults)
        } catch {
            throw ContextManagerError.persistenceFailed(error)
        }
    }
}
