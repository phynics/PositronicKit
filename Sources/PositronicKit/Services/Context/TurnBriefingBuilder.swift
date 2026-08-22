import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Builds the turn briefing — the selected memory/workspace material for one turn.
actor TurnBriefingBuilder {
    let workspace: (any Workspace)?
    let pipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>
    private let logger = Logger.module(named: "turn-briefing-builder")

    init(
        workspace: (any Workspace)? = nil,
        memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore(),
        pipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil
    ) {
        self.workspace = workspace
        self.pipeline = pipeline ?? Pipeline(stages: Self.defaultStages(
            workspace: workspace,
            memoryStore: memoryStore
        ))
    }

    /// Provides the standard stages for context gathering.
    static func defaultStages(
        workspace: (any Workspace)? = nil,
        memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore()
    ) -> [any PipelineStage<ContextPipelineContext, ContextGatheringEvent>] {
        return [
            QueryAugmentationStage(),
            MemoryRetrievalStage(memoryStore: memoryStore),
            NoteDiscoveryStage(workspace: workspace),
            ContextAssemblyStage(logger: Logger.module(named: "context-assembly")),
        ]
    }

    /// Gather all relevant context for a given user query
    /// - Parameters:
    ///   - query: The user's input text
    ///   - history: Recent thread history to provide context for the search
    ///   - limit: Maximum number of memories to retrieve
    ///   - tagGenerator: A function to generate tags from the query (e.g. via LLM)
    ///   - overridePipeline: An optional pipeline to use instead of the default one
    /// - Returns: A stream of progress events, finishing with the structured context
    func gatherContext(
        for query: String,
        history: [Message] = [],
        limit: Int = 5,
        tagGenerator: (@Sendable (String) async throws -> [String])? = nil,
        overridePipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil
    ) -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        return AsyncThrowingStream<ContextGatheringEvent, Error> { continuation in
            let task = Task {
                let startTime = Date().timeIntervalSinceReferenceDate
                logger.debug(
                    "Gathering context for query length: \(query.count), history count: \(history.count)"
                )

                let context = ContextPipelineContext(
                    query: query,
                    history: history,
                    limit: limit,
                    tagGenerator: tagGenerator,
                    startTime: startTime
                )

                do {
                    let activePipeline = overridePipeline ?? pipeline
                    let stream = activePipeline.execute(context)
                    for try await event in stream {
                        continuation.yield(event)
                    }

                    if let data = await context.contextData {
                        continuation.yield(.progress(.complete))
                        continuation.yield(.complete(data))
                    }
                    continuation.finish()
                } catch {
                    logger.error("Context gathering failed: \(ErrorKit.userFriendlyMessage(for: error))")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
