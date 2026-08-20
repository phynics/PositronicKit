import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Pipeline stage responsible for augmenting the search query with recent thread history.
struct QueryAugmentationStage: PipelineStage {
    private let logger = Logger.module(named: "query-augmentation")

    /// Initializes a new query augmentation stage.
    init() {}

    /// Augments the user's query with relevant context from the history.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields an augmentation progress event.
    func process(
        _ context: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        let query = context.query
        let history = context.history

        let augmented = buildAugmentedContext(query: query, history: history)
        await context.setAugmentedQuery(augmented)

        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(.augmenting))
            continuation.finish()
        }
    }

    /// Combines recent thread history with the current query to provide more context for search.
    /// - Parameters:
    ///   - query: The original user input query.
    ///   - history: Recent messages in the thread.
    /// - Returns: A string combining history and the query.
    private func buildAugmentedContext(query: String, history: [Message]) -> String {
        guard !history.isEmpty else { return query }

        // Take the last few user/assistant messages to provide context for tags
        // Exclude tool responses as they might be too technical/long for tag generation context
        let historyContext =
            history
                .filter { $0.role == .user || $0.role == .assistant }
                .suffix(3)
                .map { $0.content }
                .joined(separator: " ")

        if historyContext.isEmpty { return query }

        let augmented = "\(historyContext) \(query)"
        logger.debug("Augmented tag context: \(augmented)")
        return augmented
    }
}
