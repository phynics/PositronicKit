import Dependencies
import Foundation
import Logging
import PKPrompt
import PKShared
import OpenAI

/// Unified chat engine that handles both interactive chat and autonomous agent execution.
/// Returns `AsyncThrowingStream<ChatEvent>` for all use cases — callers decide how to consume.
///
/// The engine orchestrates the entire lifecycle of a chat turn, including context gathering,
/// LLM interaction, tool execution, and state persistence.
public struct ChatEngine: Sendable {
    // MARK: - Constants

    public enum Constants {
        public static let maxHistoryTokens = 120_000
        public static let historyTokenBuffer = 4000
        public static let sentinelToolName = "tool_call"
        public static let defaultMaxTurns = 5
        public static let maxRemoteDepth = 3
    }

    @Dependency(\.timelineManager) var timelineManager
    @Dependency(\.agentInstanceStore) var agentInstanceStore
    @Dependency(\.requestOriginStore) var requestOriginStore
    @Dependency(\.messageStore) var messageStore
    @Dependency(\.llmService) var llmService
    @Dependency(\.toolRouter) var toolRouter
    @Dependency(\.chatTurnPlugins) var chatTurnPlugins

    let logger = Logger.module(named: "com.positronickit.chat-engine")

    var additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []

    public init() {}

    // MARK: - Public API

    /// Execute a chat turn and return a stream of deltas.
    /// - Parameters:
    ///   - timelineId: The unique identifier for the chat session.
    ///   - message: The user's input message.
    ///   - tools: Pre-resolved tools available for this turn.
    ///   - toolOutputs: Optional list of tool outputs submitted from a previous externally executed turn.
    ///   - contextManager: Optional context manager for RAG. If nil, no context is gathered.
    ///   - systemInstructions: Optional system instructions to override the default.
    ///   - agentInstanceId: Optional identifier for the agent instance.
    ///   - maxTurns: Maximum number of LLM turns before stopping. Defaults to 5.
    /// - Returns: An asynchronous stream of chat events.
    public func execute(
        timelineId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        contextManager: ContextManager? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = Constants.defaultMaxTurns,
        generationParameters: GenerationParameters? = nil,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyPipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let sid = ANSIColors.colorize(timelineId.uuidString.prefix(8).lowercased(), color: ANSIColors.brightBlue)
        logger.info("Starting chat stream for timeline \(sid)")

        guard await llmService.isConfigured else { throw ChatEngineError.llmServiceNotConfigured }

        let context = try await prepareSession(
            timelineId: timelineId,
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            contextManager: contextManager,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns,
            generationParameters: generationParameters,
            contextPipeline: contextPipeline,
            assemblyPipeline: assemblyPipeline
        )

        return AsyncThrowingStream<ChatEvent, Error> { continuation in
            let task = Task {
                await self.runChatLoop(continuation: continuation, context: context)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Core Loop

    private enum LoopContinuation {
        case stop
        case continueWith([ChatQuery.ChatCompletionMessageParam])
    }

    /// The heart of the agentic loop. Orchestrates multiple turns until the agent finishes
    /// or reaches the max turn limit.
    private func runChatLoop(
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        context: ChatTurnContext
    ) async {
        // 1. Emit initial RAG context for frontend observability
        continuation.yield(.generationContext(ChatMetadata(
            memories: context.contextData.memories.map { $0.memory.id },
            files: context.contextData.notes.map { $0.name }
        )))

        var loopMessages = context.currentMessages
        var turnCount = 0
        var priorOutput = ""

        // 2. Main reasoning loop (ReAct loop)
        while turnCount < context.maxTurns {
            turnCount += 1
            let turnContext = context.forTurn(
                turnCount: turnCount,
                messages: loopMessages
            )

            // Execute one turn (LLM call + automatic runtime tool routing)
            let signal = await runOneTurn(continuation: continuation, context: turnContext)

            // Accumulate thinking and response manually from the current turn
            let currentThinking = await turnContext.outputs.fullThinking
            let currentResponse = await turnContext.outputs.fullResponse
            priorOutput += currentThinking
            priorOutput += currentResponse

            switch signal {
            case .stop:
                // Turn finished without further internal actions required
                var pluginMessages: [ChatQuery.ChatCompletionMessageParam] = []
                let completedTurn = CompletedTurn(
                    timelineId: context.timelineId,
                    agentInstanceId: context.agentInstanceId,
                    turnCount: turnCount,
                    fullResponse: priorOutput,
                    modelName: context.modelName
                )

                // 3. Post-turn plugin execution (e.g. autonomous reactions, background jobs)
                do {
                    for plugin in chatTurnPlugins {
                        pluginMessages += try await plugin.afterTurn(completedTurn)
                    }
                } catch {
                    logger.error("Plugin error after turn \(turnCount): \(error)")
                    continuation.finish(throwing: error)
                    return
                }

                // If plugins added context, resume the loop for a follow-up turn
                if !pluginMessages.isEmpty, turnCount < context.maxTurns {
                    loopMessages += pluginMessages
                } else {
                    continuation.finish()
                    return
                }

            case let .continueWith(newMessages):
                // A tool result or internal thought needs the LLM to process it in the next turn
                loopMessages += newMessages
                // Track appended messages for compaction awareness
                if let history = context.promptHistory {
                    let responseText = await turnContext.outputs.fullResponse + turnContext.outputs.fullThinking
                    _ = await history.append(
                        messageCount: newMessages.count,
                        estimatedTokens: TokenEstimator.estimate(text: responseText)
                    )
                }
            }
        }

        logger.warning("Max turns (\(context.maxTurns)) reached for timeline \(context.timelineId)")
        continuation.finish()
    }

    private func runOneTurn(
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        context: ChatTurnContext
    ) async -> LoopContinuation {
        let sid = ANSIColors.colorize(
            context.timelineId.uuidString.prefix(8).lowercased(), color: ANSIColors.brightBlue
        )
        let turnLabel = ANSIColors.colorize("\(context.turnCount)", color: ANSIColors.brightYellow)
        logger.info("Starting turn \(turnLabel) for timeline \(sid)")

        do {
            try Task.checkCancellation()
            logger.trace("Turn \(turnLabel): starting pipeline for \(sid)")
            try await processTurn(context: context, continuation: continuation)
            logger.trace("Turn \(turnLabel): pipeline complete for \(sid)")
            return try await handleToolCallsAfterTurn(context: context, continuation: continuation)
        } catch is CancellationError {
            continuation.yield(.generationCancelled())
            continuation.finish()
            return .stop
        } catch {
            logger.error("Error in chat loop turn \(context.turnCount): \(error)")
            continuation.finish(throwing: error)
            return .stop
        }
    }

    /// Delegates tool call handling to the ToolRouter and maps the result to a loop decision.
    private func handleToolCallsAfterTurn(
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> LoopContinuation {
        let result = try await toolRouter.processToolCalls(
            outputs: context.outputs,
            timelineId: context.timelineId,
            availableTools: context.availableTools,
            continuation: continuation
        )

        switch result {
        case .noToolCalls, .deferredExternally:
            return .stop
        case let .continueWith(messages):
            return .continueWith(messages)
        }
    }

    private func processTurn(
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var pipeline = Pipeline<ChatTurnContext, ChatEvent>()
            .add(LLMStreamingStage(llmService: llmService, logger: logger))
            .add(ToolCallExtractionStage(logger: logger))
            .add(MessagePersistenceStage(messageStore: messageStore, logger: logger))

        for stage in additionalStages {
            pipeline = pipeline.add(stage)
        }

        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }
}
