import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Pipeline stage responsible for retrieving tagged memories.
struct MemoryRetrievalStage: PipelineStage {
    private let memoryStore: any MemoryStoreProtocol

    private let logger = Logger.module(named: "memory-retrieval")
    private let ranker = ContextRanker()

    /// Initializes a new memory retrieval stage.
    init(
        memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore()
    ) {
        self.memoryStore = memoryStore
    }

    /// Retrieves relevant memories and tags for the query in the context.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields progress events as retrieval proceeds.
    func process(
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
                        tags: results.tags
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Fetches tagged memories required for the query.
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
    ) async throws -> (memories: [Memory], tags: [String]) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (memories: [], tags: [])
        }

        guard try await memoryStore.hasAnyMemory() else {
            logger.info("Recall: 0 memories selected from 0 tag matches")
            return (memories: [], tags: [])
        }

        let tags = await generateTagsSafely(tagContext: tagContext, tagGenerator: tagGenerator, onProgress: onProgress)

        if Task.isCancelled {
            return (memories: [], tags: [])
        }

        onProgress?(.searching)
        let tagResults: [Memory]
        do {
            tagResults = try await memoryStore.searchMemories(matchingAnyTag: tags)
        } catch {
            throw TurnBriefingBuilderError.persistenceFailed(error)
        }

        onProgress?(.ranking)
        let finalResults = ranker.rankMemories(tagResults)
        let topResults = Array(finalResults.prefix(limit))

        logger.info("Recall: \(topResults.count) memories selected from \(tagResults.count) tag matches")

        return (
            memories: topResults, tags: tags
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
}
