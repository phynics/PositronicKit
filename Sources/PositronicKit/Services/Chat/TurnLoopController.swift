import Foundation
import Logging
import PKPrompt
import PKShared

/// Owns the ReAct continuation loop: per-turn stage execution, runtime-managed tool
/// continuation, post-turn plugin follow-up, max-turns enforcement, and cancellation
/// handling (including STAB-1 partial persistence on the error path).
///
/// Extracted from `ChatEngine` (PKARCH-001). `ChatEngine.execute` builds a `ChatTurnContext`
/// via `TurnPreparer`, then hands it to this controller to drive the streaming loop. Prompt
/// follow-up synthesis is delegated to `PromptSnapshotBuilder`; partial-assistant
/// persistence on failure/cancellation is delegated to `PartialAssistantPersistence`.
struct TurnLoopController {
    let dependencies: ChatEngine.Dependencies
    let logger: Logger
    let additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>]
    let snapshotBuilder: PromptSnapshotBuilder
    let partialPersistence: PartialAssistantPersistence

    // MARK: - Core Loop

    private enum LoopContinuation {
        case stop
        case continueWith([LLMMessage])
    }

    /// The heart of the agentic loop. Orchestrates multiple turns until the agent finishes
    /// or reaches the max turn limit.
    func runChatLoop(
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        context: ChatTurnContext
    ) async {
        // 1. Emit initial RAG context for frontend observability
        continuation.yield(.generationContext(ChatMetadata(
            memories: context.contextData.memories.map { $0.memory.id },
            files: context.contextData.notes.map { $0.name }
        )))

        var loopMessages = context.currentMessages
        var loopRenderedPrompt = context.renderedPrompt
        var loopPromptHistoryUpdate = context.promptHistoryUpdate
        var turnCount = 0
        var priorOutput = ""

        // 2. Main reasoning loop (ReAct loop)
        while turnCount < context.maxTurns {
            turnCount += 1
            let turnContext = context.forTurn(
                turnCount: turnCount,
                messages: loopMessages,
                renderedPrompt: loopRenderedPrompt,
                promptHistoryUpdate: loopPromptHistoryUpdate
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
                        let snapshot = await snapshotBuilder.buildFollowUpSnapshot(
                            from: turnContext,
                            appendedMessages: pluginMessages,
                            nextTurnIndex: turnCount
                        )
                        loopRenderedPrompt = snapshot.renderedPrompt
                        loopPromptHistoryUpdate = snapshot.promptHistoryUpdate
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
                let snapshot = await snapshotBuilder.buildFollowUpSnapshot(
                    from: turnContext,
                    appendedMessages: newMessages,
                    nextTurnIndex: turnCount
                )
                loopRenderedPrompt = snapshot.renderedPrompt
                loopPromptHistoryUpdate = snapshot.promptHistoryUpdate
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
            await publishTurnInspectionIfNeeded(context: context)
            try await processTurn(context: context, continuation: continuation)
            logger.trace("Turn \(turnLabel): pipeline complete for \(sid)")
            return try await handleToolCallsAfterTurn(context: context, continuation: continuation)
        } catch is CancellationError {
            // STAB-1: the stream was cancelled mid-flight. `MessagePersistenceStage` only runs on
            // success, so persist whatever partial assistant text/thinking (and any accumulated
            // tool calls) the user already watched stream in, tagged `.cancelled`. The cancel
            // event is still surfaced below — the UI needs it (STAB-5 handles retry separately).
            await partialPersistence.persistPartialAssistantIfNeeded(context: context, status: .cancelled)
            continuation.yield(.generationCancelled())
            continuation.finish()
            return .stop
        } catch {
            logger.error("Error in chat loop turn \(context.turnCount): \(error)")
            // STAB-1: same data-loss fix for the failure path (network drop, provider 4xx/5xx,
            // idle timeout). A stage-thrown `CancellationError` is wrapped by `Pipeline` as
            // `PipelineError.stageFailed` and lands here — unwrap it so a mid-stream
            // cancellation is still tagged `.cancelled` rather than `.partial`. The error event
            // is still surfaced to the UI (re-thrown below); STAB-5 handles retry separately.
            let status: Message.MessageStatus = Self.isCancellationOrigin(error) ? .cancelled : .partial
            await partialPersistence.persistPartialAssistantIfNeeded(context: context, status: status)
            continuation.finish(throwing: error)
            return .stop
        }
    }

    /// Returns `true` if `error` represents cancellation, unwrapping `PipelineError` stage
    /// wrappers (a stage-thrown `CancellationError` is wrapped as
    /// `PipelineError.stageFailed(id, CancellationError())` before reaching `runOneTurn`).
    private static func isCancellationOrigin(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if case let PipelineError.stageFailed(_, underlying) = error, underlying is CancellationError {
            return true
        }
        if case let PipelineError.cleanupFailed(_, underlying) = error, underlying is CancellationError {
            return true
        }
        return false
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

        // Record whether the turn produced tool calls and how much assistant text it emitted:
        // an empty turn with no tool calls points upstream at the model / provider adapter
        // rather than the tool router.
        let contentChars = await context.outputs.fullResponse.count
        switch result {
        case .noToolCalls:
            logger.debug("Turn \(context.turnCount): no tool calls; assistant content chars=\(contentChars)")
        case .deferredExternally:
            logger.debug("Turn \(context.turnCount): tool calls deferred for external execution")
        case let .continueWith(messages):
            logger.debug("Turn \(context.turnCount): \(messages.count) tool-result message(s) to feed back; assistant content chars=\(contentChars)")
        }

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
            streamTimeout: dependencies.streamTimeout,
            additionalStages: additionalStages
        )
        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }

    private func publishTurnInspectionIfNeeded(context: ChatTurnContext) async {
        // Audit trail: log which precondition failed so an operator asking "why didn't my
        // inspector fire?" gets a reason instead of silence (PKLOG-001).
        let baseMeta: Logger.Metadata = [
            "conversationID": .string(context.timelineId.uuidString),
            "turnIndex": .string("\(context.turnCount)"),
        ]
        guard let inspector = dependencies.turnInspector else {
            logger.debug("Turn inspection skipped: no turn inspector registered", metadata: baseMeta)
            return
        }
        guard let renderedPrompt = context.renderedPrompt else {
            logger.debug("Turn inspection skipped: no rendered prompt available", metadata: baseMeta)
            return
        }
        guard let update = context.promptHistoryUpdate else {
            logger.debug("Turn inspection skipped: no prompt history update", metadata: baseMeta)
            return
        }
        guard let diff = update.diff else {
            logger.debug("Turn inspection skipped: prompt diff unavailable", metadata: baseMeta)
            return
        }

        // `context.turnCount` resets to 0 at the start of every `execute()` call (every user
        // send), so it cannot identify a persisted inspection row uniquely across a whole
        // conversation — a second send's first round-trip would collide with the first send's
        // row (`TimelinePromptHistory.nextInspectionTurnIndex` fixes this; see YAK-16).
        let turnIndex = await context.promptHistory?.nextInspectionTurnIndex() ?? (context.turnCount - 1)

        let turnIdentity = TurnIdentity(sendId: context.sendId, roundTrip: max(context.turnCount - 1, 0))

        await inspector.didComposeTurn(TurnInspection(
            identity: turnIdentity,
            timelineId: context.timelineId,
            agentInstanceId: context.agentInstanceId,
            turnIndex: turnIndex,
            model: context.modelName,
            rendered: renderedPrompt,
            sentMessages: context.currentMessages,
            journal: TurnJournalSnapshot(
                overlay: diff.publicJournalDiff,
                stablePrefixCount: diff.stablePrefixCount,
                didCompact: update.didCompact
            ),
            estimatedTokens: renderedPrompt.estimatedTokens
        ))
    }
}
