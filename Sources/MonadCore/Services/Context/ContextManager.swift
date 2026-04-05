import ErrorKit
import Foundation
import Logging
import MonadPrompt
import MonadShared

/// Manages the retrieval and organization of context for the chat
public actor ContextManager {
    public let workspace: (any WorkspaceProtocol)?
    public let pipeline: ContextPipeline
    private let logger = Logger.module(named: "com.monad.ContextManager")

    public init(
        workspace: (any WorkspaceProtocol)? = nil,
        pipeline: ContextPipeline? = nil
    ) {
        self.workspace = workspace
        self.pipeline = pipeline ?? ContextPipeline(stages: Self.defaultStages(workspace: workspace))
    }

    /// Provides the standard stages for context gathering.
    public static func defaultStages(
        workspace: (any WorkspaceProtocol)? = nil
    ) -> [any PipelineStage<ContextPipelineContext, ContextGatheringEvent>] {
        return [
            QueryAugmentationStage(),
            MemoryRetrievalStage(),
            NoteDiscoveryStage(workspace: workspace),
            ContextAssemblyStage(logger: Logger.module(named: "com.monad.ContextAssemblyStage")),
        ]
    }

    /// Gather all relevant context for a given user query
    /// - Parameters:
    ///   - query: The user's input text
    ///   - history: Recent conversation history to provide context for the search
    ///   - limit: Maximum number of memories to retrieve
    ///   - tagGenerator: A function to generate tags from the query (e.g. via LLM)
    ///   - overridePipeline: An optional pipeline to use instead of the default one
    /// - Returns: A stream of progress events, finishing with the structured context
    public func gatherContext(
        for query: String,
        history: [Message] = [],
        limit: Int = 5,
        tagGenerator: (@Sendable (String) async throws -> [String])? = nil,
        overridePipeline: ContextPipeline? = nil
    ) -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        return AsyncThrowingStream<ContextGatheringEvent, Error> { continuation in
            let task = Task {
                let startTime = CFAbsoluteTimeGetCurrent()
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
