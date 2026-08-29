import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Typed outcome of a single turn, driving the outer loop's continuation decision.
///
/// Terminal outcomes skip snapshot building, message appending, and further LLM turns, so no
/// runtime activity occurs after the stream has been finished with an error or cancellation.
private enum LoopContinuation {
    /// The turn completed normally (no pending tool calls).
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
    /// A tool result could not be persisted. The router already emitted `.persistenceFailed`,
    /// while the durable assistant row remains pending for a retry; no provider follow-up is safe.
    case persistenceFailed
    /// At least one tool call was deferred for external (host-side) execution. Terminal: the
    /// outer loop emits `.deferredForExternalTool()` and finishes the stream without running
    /// another LLM turn (PKRR-011).
    case deferredExternally
}

/// The loop chooses the terminal outcome and any path-specific policy. This value carries only the
/// mechanics that are safe to apply after the repository has accepted that outcome.
private struct TerminalDecision {
    enum Delivery {
        case none
        case completion
        case event(TurnEvent)
    }

    let outcome: TurnOutcome
    let delivery: Delivery
    let streamError: Error?

    init(
        outcome: TurnOutcome,
        delivery: Delivery,
        streamError: Error? = nil
    ) {
        self.outcome = outcome
        self.delivery = delivery
        self.streamError = streamError
    }

    static func delivery(for outcome: TurnOutcome) -> Delivery {
        switch outcome {
        case .completed:
            return .completion
        case .cancelled:
            return .event(.generationCancelled())
        case let .failed(message):
            return .event(.error(message))
        case let .interrupted(reason):
            return .event(.error(reason))
        }
    }
}

private enum TerminalRepositoryError: Error, Sendable {
    case missingOutcome(UUID)
}

// MARK: - Turn Loop

extension TurnEngine {
    /// The heart of the agentic loop. Orchestrates model rounds until the agent finishes
    /// or reaches the maximum model-round limit.
    func runTurnLoop(
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
        context: TurnContext
    ) async {
        let snapshotBuilder = PromptSnapshotBuilder()
        let partialPersistence = PartialAssistantPersistence(
            runtimeRepository: dependencies.runtimeRepository
        )

        var loopMessages = context.currentMessages
        var loopRenderedPrompt = context.renderedPrompt
        var loopPromptHistoryUpdate = context.promptHistoryUpdate
        var modelRoundIndex = 0
        var terminalContext = context

        scheduleAgentActivity(
            AgentActivity(
                kind: .turnStarted,
                threadID: context.threadID,
                turnID: context.turnID,
                requestID: context.requestId,
                agentID: context.agentId,
                modelRoundIndex: 0
            ),
            context: context
        )

        // 2. Main reasoning loop (ReAct loop)
        while modelRoundIndex < context.maxModelRounds {
            modelRoundIndex += 1
            let turnContext = context.forTurn(
                modelRoundIndex: modelRoundIndex,
                messages: loopMessages,
                renderedPrompt: loopRenderedPrompt,
                promptHistoryUpdate: loopPromptHistoryUpdate
            )
            terminalContext = turnContext

            // Execute one turn (LLM call + automatic runtime tool routing)
            let signal = await runOneTurn(
                continuation: continuation,
                context: turnContext,
                partialPersistence: partialPersistence
            )

            switch signal {
            case .completed:
                await commitTerminal(
                    decision: TerminalDecision(
                        outcome: .completed,
                        delivery: .completion
                    ),
                    context: turnContext,
                    continuation: continuation
                )
                return

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
                let snapshot: (renderedPrompt: RenderedPrompt?, promptHistoryUpdate: PromptHistoryUpdate?)
                do {
                    snapshot = try await snapshotBuilder.buildFollowUpSnapshot(
                        from: turnContext,
                        appendedMessages: newMessages,
                        nextTurnIndex: modelRoundIndex
                    )
                } catch {
                    // Snapshot failures terminate the send after preparation, so the caller may
                    // retry with the same request ID.
                    await commitTerminal(
                        decision: TerminalDecision(
                            outcome: .failed(message: String(describing: error)),
                            delivery: .none,
                            streamError: wrapForeignError(error)
                        ),
                        context: turnContext,
                        continuation: continuation
                    )
                    return
                }
                loopRenderedPrompt = snapshot.renderedPrompt
                loopPromptHistoryUpdate = snapshot.promptHistoryUpdate

            case .cancelled:
                // Terminal: the stream was cancelled mid-flight. `runOneTurn` already
                // persisted the partial turn, surfaced `.generationCancelled()`, and finished
                // the continuation. No snapshot, message append, or further
                // LLM turn is permitted after terminal delivery (PKRR-003).
                return

            case .failed:
                // Terminal: the stream failed. `runOneTurn` already persisted the partial
                // turn and finished the continuation with the error. No
                // snapshot, message append, or further LLM turn is permitted after terminal
                // delivery (PKRR-003).
                return

            case .deferredExternally:
                // Terminal: at least one tool call was deferred for external execution. The
                // stream pauses for host-side tool execution — emit a distinct terminal event
                // so consumers can distinguish deferred external tool work from normal
                // completion, then finish without another LLM turn
                // (PKRR-011).
                // Keep the durable active Turn visible when terminal persistence fails so a host
                // can recover it instead of retrying against an unknown state.
                await commitTerminal(
                    decision: TerminalDecision(
                        outcome: .interrupted(reason: "External tool execution deferred."),
                        delivery: .event(.deferredForExternalTool())
                    ),
                    context: turnContext,
                    continuation: continuation
                )
                return

            case .persistenceFailed:
                // Terminal but recoverable: the router emitted `.persistenceFailed` and left the
                // assistant's pending tool call in durable history. Release the turn reservation
                // so the caller can retry with the existing pending-call submission semantics.
                await commitTerminal(
                    decision: TerminalDecision(
                        outcome: .failed(message: "Tool result persistence failed."),
                        delivery: .none
                    ),
                    context: turnContext,
                    continuation: continuation
                )
                return
            }
        }

        logger.warning("Max model rounds (\(context.maxModelRounds)) reached for thread \(context.threadID)", metadata: [
            LogKeys.threadID: .string(context.threadID.uuidString),
            LogKeys.turnID: .string(context.turnID.uuidString),
            LogKeys.requestID: .string(context.requestId.uuidString),
            LogKeys.modelRoundIndex: .string("\(modelRoundIndex)"),
        ])
        // Terminal: the loop exhausted its max-model-round budget while tool calls were still pending.
        // Emit a distinct terminal event so consumers can distinguish model-round exhaustion from
        // normal completion instead of the stream silently finishing as if it succeeded
        // (PKRR-011).
        await commitTerminal(
            decision: TerminalDecision(
                outcome: .failed(message: "model-round-limit"),
                delivery: .event(.maxModelRoundsReached())
            ),
            context: terminalContext,
            continuation: continuation
        )
    }
}

// MARK: - Turn Execution

private extension TurnEngine {
    func runOneTurn(
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
        context: TurnContext,
        partialPersistence: PartialAssistantPersistence
    ) async -> LoopContinuation {
        let sid = context.threadID.uuidString.prefix(8).lowercased()
        let turnLabel = "\(context.modelRoundIndex)"
        logger.info("Starting turn \(turnLabel) for thread \(sid)")

        do {
            try Task.checkCancellation()
            try await dependencies.runtimeRepository.beginModelRound(
                turnID: context.turnID,
                modelRoundIndex: context.modelRoundIndex,
                now: Date()
            )
            try await dependencies.runtimeRepository.recordProviderRequest(
                turnID: context.turnID,
                modelRoundIndex: context.modelRoundIndex,
                correlation: TurnCorrelation(kind: "model-round", value: "\(context.modelRoundIndex)"),
                now: Date()
            )
            logger.trace("Turn \(turnLabel): starting pipeline for \(sid)")
            try await processTurn(context: context, continuation: continuation)
            // Pipeline stages expose streams backed by their own producer tasks. If this Turn is
            // cancelled while one of those producers is finishing, the stream can close normally
            // even though the owning Turn task is already cancelled. Recheck ownership before any
            // success/tool-routing path can durably complete the Turn.
            try Task.checkCancellation()
            logger.trace("Turn \(turnLabel): pipeline complete for \(sid)")
            return try await handleToolCallsAfterTurn(context: context, continuation: continuation)
        } catch is CancellationError {
            // STAB-1: the stream was cancelled mid-flight. `MessagePersistenceStage` only runs on
            // success, so persist whatever partial assistant text/thinking (and any accumulated
            // tool calls) the user already watched stream in, tagged `.cancelled`. The cancel
            // event is still surfaced below — the UI needs it (STAB-5 handles retry separately).
            await partialPersistence.persistPartialAssistantIfNeeded(context: context, status: .cancelled)
            await commitTerminal(
                decision: TerminalDecision(
                    outcome: .cancelled(reason: "Turn task cancelled."),
                    delivery: .event(.generationCancelled())
                ),
                context: context,
                continuation: continuation
            )
            return .cancelled
        } catch {
            logger.error("Error in turn loop turn \(context.modelRoundIndex): \(error)", metadata: [
                LogKeys.threadID: .string(context.threadID.uuidString),
                LogKeys.turnID: .string(context.turnID.uuidString),
                LogKeys.requestID: .string(context.requestId.uuidString),
                LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
            ])
            // STAB-1: same data-loss fix for the failure path (network drop, provider 4xx/5xx,
            // idle timeout). A stage-thrown `CancellationError` is wrapped by `Pipeline` as
            // `PipelineError.stageFailed` and lands here — unwrap it so a mid-stream
            // cancellation is still tagged `.cancelled` rather than `.partial`. The error event
            // is still surfaced to the UI (re-thrown below); STAB-5 handles retry separately.
            let isCancellation = Self.isCancellationOrigin(error)
            let status: Message.MessageStatus = isCancellation ? .cancelled : .partial
            await partialPersistence.persistPartialAssistantIfNeeded(context: context, status: status)
            await commitTerminal(
                decision: TerminalDecision(
                    outcome: isCancellation
                        ? .cancelled(reason: "Turn task cancelled.")
                        : .failed(message: String(describing: error)),
                    delivery: .none,
                    streamError: error
                ),
                context: context,
                continuation: continuation
            )
            // Terminal outcome: a wrapped cancellation is still a cancellation for loop-control
            // purposes, so the outer loop skips any follow-up either way.
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
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws -> LoopContinuation {
        let result = try await dependencies.toolRouter.processToolCalls(
            outputs: context.outputs,
            threadId: context.threadID,
            turnID: context.turnID,
            modelRoundIndex: context.modelRoundIndex,
            availableTools: context.availableTools,
            workspaceToolCatalog: context.workspaceToolCatalog,
            continuation: continuation
        )

        // Record whether the turn produced tool calls and how much assistant text it emitted:
        // an empty turn with no tool calls points upstream at the model / provider adapter
        // rather than the tool router.
        let contentChars = await context.outputs.fullResponse.count
        let turnMeta: Logger.Metadata = [
            LogKeys.threadID: .string(context.threadID.uuidString),
            LogKeys.turnID: .string(context.turnID.uuidString),
            LogKeys.requestID: .string(context.requestId.uuidString),
            LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
        ]
        switch result {
        case .noToolCalls:
            logger.debug("Turn \(context.modelRoundIndex): no tool calls; assistant content chars=\(contentChars)", metadata: turnMeta)
        case .deferredExternally:
            logger.debug("Turn \(context.modelRoundIndex): tool calls deferred for external execution", metadata: turnMeta)
        case .persistenceFailed:
            logger.debug("Turn \(context.modelRoundIndex): tool result persistence failed; stopping before follow-up", metadata: turnMeta)
        case let .continueWith(messages):
            logger.debug("Turn \(context.modelRoundIndex): \(messages.count) tool-result message(s) to feed back; assistant content chars=\(contentChars)", metadata: turnMeta)
        }

        switch result {
        case .noToolCalls:
            return .completed
        case .deferredExternally:
            return .deferredExternally
        case .persistenceFailed:
            return .persistenceFailed
        case let .continueWith(messages):
            return .continueWith(messages)
        }
    }

    func processTurn(
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws {
        let pipeline = TurnPipelineBuilder.makePipeline(
            llmService: dependencies.llmService,
            runtimeRepository: dependencies.runtimeRepository,
            streamTimeout: dependencies.streamTimeout,
            diagnosticSnapshotConfiguration: dependencies.diagnosticSnapshotConfiguration,
            loggingConfiguration: dependencies.loggingConfiguration,
            additionalStages: additionalStages
        )
        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }

    /// Starts best-effort activity delivery without putting provider execution behind a host sink.
    func scheduleAgentActivity(_ activity: AgentActivity, context: TurnContext) {
        guard let sink = dependencies.agentActivitySink else { return }
        let turnID = context.turnID
        let logger = self.logger
        Task {
            do {
                try await sink.record(activity)
            } catch {
                await TurnEngine.persistCustomizationNotice(
                    repository: self.dependencies.runtimeRepository,
                    logger: logger,
                    code: .agentActivitySinkFailed,
                    turnID: turnID,
                    message: ErrorKit.userFriendlyMessage(for: error)
                )
            }
        }
    }

}

// MARK: - Terminal Delivery

private extension TurnEngine {
    /// Applies terminal mechanics in one order: durable truth, best-effort observations,
    /// reservation release, and finally the consumer-facing terminal signal.
    func commitTerminal(
        decision: TerminalDecision,
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async {
        let durableOutcome: TurnOutcome
        do {
            durableOutcome = try await completeTerminalOutcome(
                context: context,
                outcome: decision.outcome
            )
        } catch {
            logger.error("Unable to durably record terminal Turn outcome: \(error)")
            continuation.finish(throwing: error)
            return
        }

        await emitTerminalSinks(context: context, outcome: durableOutcome)

        let usesRequestedOutcome = durableOutcome == decision.outcome
        let delivery = usesRequestedOutcome
            ? decision.delivery
            : TerminalDecision.delivery(for: durableOutcome)
        switch delivery {
        case .none:
            break
        case let .event(event):
            continuation.yield(event)
        case .completion:
            await emitTerminalSidecarCompletionIfNeeded(
                context: context,
                continuation: continuation
            )
            let message = await context.outputs.terminalAssistantMessage
            let metadata = await context.outputs.terminalCompletionMetadata
            if let message {
                continuation.yield(.generationCompleted(
                    message: message.toMessage(),
                    metadata: metadata ?? APIResponseMetadata()
                ))
            } else {
                // A completed Turn normally has the assistant row captured by the persistence
                // stage. Keep the existing empty fallback only for a missing terminal row.
                continuation.yield(.completedEmpty(finishReason: metadata?.finishReason))
            }
        }

        if usesRequestedOutcome, let streamError = decision.streamError {
            continuation.finish(throwing: streamError)
        } else {
            continuation.finish()
        }
    }

    func completeTerminalOutcome(
        context: TurnContext,
        outcome: TurnOutcome
    ) async throws -> TurnOutcome {
        let finalMessage: ThreadMessage?
        if case .completed = outcome {
            if let terminalMessage = await context.outputs.terminalAssistantMessage {
                finalMessage = terminalMessage
            } else {
                let messages = try await dependencies.runtimeRepository.fetchMessages(for: context.threadID)
                let userIndex = messages.firstIndex(where: { $0.id == context.requestId })
                finalMessage = userIndex.flatMap { index in
                    messages.dropFirst(index + 1).last(where: {
                        $0.role == Message.MessageRole.assistant.rawValue
                    })
                }
            }
        } else {
            finalMessage = nil
        }

        let record = try await dependencies.runtimeRepository.completeTurn(
            turnID: context.turnID,
            outcome: outcome,
            finalMessage: finalMessage,
            terminalHandle: TurnTerminalHandle(turnID: context.turnID),
            now: Date()
        )
        guard let persistedOutcome = record.outcome else {
            throw TerminalRepositoryError.missingOutcome(context.turnID)
        }
        return persistedOutcome
    }

    func emitTerminalSidecarCompletionIfNeeded(
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async {
        guard context.sidecarCommitPolicy == .terminalModelRound else { return }
        let results = await context.outputs.sidecarResults
        guard !results.isEmpty else { return }
        continuation.yield(.sidecarsCompleted(SidecarCompletion(
            identity: TurnIdentity(
                turnID: context.turnID,
                requestID: context.requestId,
                modelRoundIndex: max(context.modelRoundIndex - 1, 0)
            ),
            results: results
        )))
    }

    func emitTerminalSinks(context: TurnContext, outcome: TurnOutcome) async {
        await emitAgentActivity(
            AgentActivity(
                kind: activityKind(for: outcome),
                threadID: context.threadID,
                turnID: context.turnID,
                requestID: context.requestId,
                agentID: context.agentId,
                modelRoundIndex: context.modelRoundIndex,
                detail: outcomeDescription(outcome)
            ),
            context: context
        )
        await emitTurnOutcome(
            TurnOutcomeRecord(
                threadID: context.threadID,
                turnID: context.turnID,
                requestID: context.requestId,
                agentID: context.agentId,
                executionKind: context.executionKind,
                modelRoundIndex: context.modelRoundIndex,
                outcome: outcome
            ),
            context: context
        )
    }

    func emitAgentActivity(_ activity: AgentActivity, context: TurnContext) async {
        guard let sink = dependencies.agentActivitySink else { return }
        do {
            try await sink.record(activity)
        } catch {
            await appendCustomizationNotice(
                code: .agentActivitySinkFailed,
                turnID: context.turnID,
                message: ErrorKit.userFriendlyMessage(for: error)
            )
        }
    }

    func emitTurnOutcome(_ outcome: TurnOutcomeRecord, context: TurnContext) async {
        guard let sink = dependencies.turnOutcomeSink else { return }
        do {
            try await sink.record(outcome)
        } catch {
            await appendCustomizationNotice(
                code: .turnOutcomeSinkFailed,
                turnID: context.turnID,
                message: ErrorKit.userFriendlyMessage(for: error)
            )
        }
    }

    func activityKind(for outcome: TurnOutcome) -> AgentActivity.Kind {
        switch outcome {
        case .completed:
            return .turnFinished
        case .cancelled:
            return .turnCancelled
        case .failed, .interrupted:
            return .turnFailed
        }
    }

    func outcomeDescription(_ outcome: TurnOutcome) -> String {
        switch outcome {
        case .completed:
            return "completed"
        case let .failed(message):
            return message
        case let .cancelled(reason):
            return reason ?? "cancelled"
        case let .interrupted(reason):
            return reason
        }
    }
}
