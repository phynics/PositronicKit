import Foundation
import Logging
import PKPrompt
import PKShared

/// Unified runtime turn orchestrator for both interactive chat and autonomous execution.
/// Returns `AsyncThrowingStream<ChatEvent>` for all use cases — callers decide how to consume.
///
/// `ChatEngine` owns the internal turn loop policy for the runtime: session preparation, prompt
/// assembly handoff, per-turn stage execution, runtime-managed tool continuation, and post-turn
/// plugin follow-up. It is deliberately *not* the public customization surface for downstream
/// applications; external callers are expected to integrate through `PositronicKitCore` and the
/// higher-level extension protocols rather than depending on this concrete orchestrator directly.
struct ChatEngine: Sendable {
    struct Dependencies: Sendable {
        let timelineManager: TimelineManager
        let agentInstanceStore: any AgentInstanceStoreProtocol
        let requestOriginStore: any RequestOriginStoreProtocol
        let messageStore: any MessageStoreProtocol
        let llmService: any LLMServiceProtocol
        let toolRouter: ToolRouter
        let chatTurnPlugins: [any ChatTurnPlugin]
    }

    // MARK: - Constants

    enum Constants {
        static let maxHistoryTokens = 120_000
        static let historyTokenBuffer = 4000
        static let sentinelToolName = "tool_call"
        static let defaultMaxTurns = 5
        static let maxRemoteDepth = 3
    }

    let dependencies: Dependencies

    let logger = Logger.module(named: "com.positronickit.chat-engine")

    var additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public init() {
        let timelineManager = TimelineManager(
            workspaceRoot: FileManager.default.temporaryDirectory
        )
        let messageStore = InMemoryMessageStore()
        self.init(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore(),
                messageStore: messageStore,
                llmService: UnconfiguredLLMService(),
                toolRouter: ToolRouter(
                    timelineManager: timelineManager,
                    messageStore: messageStore
                ),
                chatTurnPlugins: []
            )
        )
    }

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

        guard await dependencies.llmService.isConfigured else { throw ChatEngineError.llmServiceNotConfigured }

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
        case continueWith([LLMMessage])
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
                do {
                    let pluginMessages = try await ChatTurnFollowUpPolicy.pluginMessages(
                        for: context,
                        turnCount: turnCount,
                        accumulatedOutput: priorOutput,
                        plugins: dependencies.chatTurnPlugins,
                        logger: logger
                    )

                    // If plugins added context, resume the loop for a follow-up turn.
                    if ChatTurnFollowUpPolicy.shouldContinueWithPluginMessages(
                        pluginMessages,
                        turnCount: turnCount,
                        maxTurns: context.maxTurns
                    ) {
                        loopMessages += pluginMessages
                    } else {
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.finish(throwing: error)
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
                        estimatedTokens: PKShared.TokenEstimator.estimate(text: responseText)
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
        let result = try await dependencies.toolRouter.processToolCalls(
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
        let pipeline = ChatTurnPipelineBuilder.makePipeline(
            llmService: dependencies.llmService,
            messageStore: dependencies.messageStore,
            logger: logger,
            additionalStages: additionalStages
        )
        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }
}
