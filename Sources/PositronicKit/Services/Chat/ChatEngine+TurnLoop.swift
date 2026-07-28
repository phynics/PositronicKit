import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Typed outcome of a single turn, driving the outer loop's continuation decision.
///
/// Only `.completed` may run `ChatTurnFollowUpPolicy` — the terminal outcomes (`.failed`,
/// `.cancelled`) skip plugin follow-up, snapshot building, message appending, and further LLM
/// turns, so no runtime activity occurs after the stream has been finished with an error or
/// cancellation (PKRR-003).
private enum LoopContinuation {
    /// The turn completed normally (no pending tool calls). Eligible for plugin follow-up.
    case completed
    /// A tool result or internal thought needs the LLM to process it in the next turn.
    case continueWith([LLMMessage])
    /// The turn failed. `runOneTurn` already persisted the partial turn and finished the
    /// continuation with the error; the outer loop must not run any post-terminal activity.
    case failed
    /// The turn was cancelled. `runOneTurn` already persisted the partial turn, surfaced
    /// `.generationCancelled()`, and finished the continuation; the outer loop must not run
    /// any post-terminal activity.
    case cancelled
}

// MARK: - Turn Loop

extension ChatEngine {
    /// The heart of the agentic loop. Orchestrates multiple turns until the agent finishes
    /// or reaches the max turn limit.
    func runChatLoop(
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        context: ChatTurnContext
    ) async {
        let snapshotBuilder = PromptSnapshotBuilder()
        let partialPersistence = PartialAssistantPersistence(
            messageStore: dependencies.messageStore
        )

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
            let signal = await runOneTurn(
                continuation: continuation,
                context: turnContext,
                partialPersistence: partialPersistence
            )

            // Accumulate thinking and response manually from the current turn
            let currentThinking = await turnContext.outputs.fullThinking
            let currentResponse = await turnContext.outputs.fullResponse
            priorOutput += currentThinking
            priorOutput += currentResponse

            switch signal {
            case .completed:
                // Turn finished without further internal actions required. Only a completed
                // turn may run plugin follow-up policy — terminal outcomes skip it (PKRR-003).
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
                    continuation.finish(throwing: wrapForeignError(error))
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
                let snapshot = await snapshotBuilder.buildFollowUpSnapshot(
                    from: turnContext,
                    appendedMessages: newMessages,
                    nextTurnIndex: turnCount
                )
                loopRenderedPrompt = snapshot.renderedPrompt
                loopPromptHistoryUpdate = snapshot.promptHistoryUpdate

            case .cancelled:
                // Terminal: the stream was cancelled mid-flight. `runOneTurn` already
                // persisted the partial turn, surfaced `.generationCancelled()`, and finished
                // the continuation. No plugin follow-up, snapshot, message append, or further
                // LLM turn is permitted after terminal delivery (PKRR-003).
                return

            case .failed:
                // Terminal: the stream failed. `runOneTurn` already persisted the partial
                // turn and finished the continuation with the error. No plugin follow-up,
                // snapshot, message append, or further LLM turn is permitted after terminal
                // delivery (PKRR-003).
                return
            }
        }

        logger.warning("Max turns (\(context.maxTurns)) reached for timeline \(context.timelineId)", metadata: [
            LogKeys.timelineID: .string(context.timelineId.uuidString),
            LogKeys.sendID: .string(context.sendId.uuidString),
            LogKeys.turnIndex: .string("\(turnCount)"),
        ])
        continuation.finish()
    }
}

// MARK: - Turn Execution

private extension ChatEngine {
    func runOneTurn(
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        context: ChatTurnContext,
        partialPersistence: PartialAssistantPersistence
    ) async -> LoopContinuation {
        let sid = ANSIColors.colorize(
            context.timelineId.uuidString.prefix(8).lowercased(), color: ANSIColors.brightBlue
        )
        let turnLabel = ANSIColors.colorize("\(context.turnCount)", color: ANSIColors.brightYellow)
        logger.info("Starting turn \(turnLabel) for timeline \(sid)")

        do {
            try Task.checkCancellation()
            logger.trace("Turn \(turnLabel): starting pipeline for \(sid)")
            await publishPromptInspectionIfNeeded(context: context)
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
            return .cancelled
        } catch {
            logger.error("Error in chat loop turn \(context.turnCount): \(error)", metadata: [
                LogKeys.timelineID: .string(context.timelineId.uuidString),
                LogKeys.sendID: .string(context.sendId.uuidString),
                LogKeys.turnIndex: .string("\(context.turnCount)"),
            ])
            // STAB-1: same data-loss fix for the failure path (network drop, provider 4xx/5xx,
            // idle timeout). A stage-thrown `CancellationError` is wrapped by `Pipeline` as
            // `PipelineError.stageFailed` and lands here — unwrap it so a mid-stream
            // cancellation is still tagged `.cancelled` rather than `.partial`. The error event
            // is still surfaced to the UI (re-thrown below); STAB-5 handles retry separately.
            let isCancellation = Self.isCancellationOrigin(error)
            let status: Message.MessageStatus = isCancellation ? .cancelled : .partial
            await partialPersistence.persistPartialAssistantIfNeeded(context: context, status: status)
            continuation.finish(throwing: error)
            // Terminal outcome: a wrapped cancellation is still a cancellation for loop-control
            // purposes, so the outer loop skips plugin follow-up either way (PKRR-003).
            return isCancellation ? .cancelled : .failed
        }
    }

    /// Returns `true` if `error` represents cancellation, unwrapping `PipelineError` stage
    /// wrappers (a stage-thrown `CancellationError` is wrapped as
    /// `PipelineError.stageFailed(id, CancellationError())` before reaching `runOneTurn`).
    static func isCancellationOrigin(_ error: Error) -> Bool {
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
    func handleToolCallsAfterTurn(
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
        let turnMeta: Logger.Metadata = [
            LogKeys.timelineID: .string(context.timelineId.uuidString),
            LogKeys.sendID: .string(context.sendId.uuidString),
            LogKeys.turnIndex: .string("\(context.turnCount)"),
        ]
        switch result {
        case .noToolCalls:
            logger.debug("Turn \(context.turnCount): no tool calls; assistant content chars=\(contentChars)", metadata: turnMeta)
        case .deferredExternally:
            logger.debug("Turn \(context.turnCount): tool calls deferred for external execution", metadata: turnMeta)
        case let .continueWith(messages):
            logger.debug("Turn \(context.turnCount): \(messages.count) tool-result message(s) to feed back; assistant content chars=\(contentChars)", metadata: turnMeta)
        }

        switch result {
        case .noToolCalls, .deferredExternally:
            return .completed
        case let .continueWith(messages):
            return .continueWith(messages)
        }
    }

    func processTurn(
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        let pipeline = ChatTurnPipelineBuilder.makePipeline(
            llmService: dependencies.llmService,
            messageStore: dependencies.messageStore,
            streamTimeout: dependencies.streamTimeout,
            additionalStages: additionalStages
        )
        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }

    func publishPromptInspectionIfNeeded(context: ChatTurnContext) async {
        // Audit trail: log which precondition failed so an operator asking "why didn't my
        // inspector fire?" gets a reason instead of silence (PKLOG-001).
        let baseMeta: Logger.Metadata = [
            LogKeys.timelineID: .string(context.timelineId.uuidString),
            LogKeys.sendID: .string(context.sendId.uuidString),
            LogKeys.turnIndex: .string("\(context.turnCount)"),
        ]
        guard let inspector = dependencies.promptObserver else {
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

        await inspector.didComposePrompt(PromptInspection(
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
