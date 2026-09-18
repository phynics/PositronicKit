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
    let streamError: TerminalStreamFailure?

    init(
        outcome: TurnOutcome,
        delivery: Delivery,
        streamError: Error? = nil
    ) {
        self.outcome = outcome
        self.delivery = delivery
        self.streamError = streamError.map(TerminalStreamFailure.init(error:))
    }

    /// Creates a failed decision with user-facing durable text and the original stream error.
    static func failed(because error: Error, streamError: Error) -> Self {
        TerminalDecision(
            outcome: .failed(message: ErrorKit.userFriendlyMessage(for: error)),
            delivery: .none,
            streamError: streamError
        )
    }
}

// MARK: - Turn Loop

/// Runs a prepared Turn: the ReAct loop, its Model Rounds, tool continuation, and the handoff
/// of the terminal decision to the runtime-owned finalizer (ADR 0010).
///
/// Extracted from `TurnEngine` so the loop has its own seam. As an extension it published eight
/// members to the package; as a module it exposes one.
struct TurnLoop: Sendable {
    let dependencies: TurnEngine.Dependencies
    let additionalStages: [any PipelineStage<TurnContext, TurnEvent>]
    let logger = Logger.module(named: "turn-engine")

    /// The heart of the agentic loop. Orchestrates model rounds until the agent finishes
    /// or reaches the maximum model-round limit.
    func runTurnLoop(
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
        context: TurnContext
    ) async {
        let snapshotBuilder = PromptSnapshotBuilder()

        var loopMessages = context.currentMessages
        var loopRenderedPrompt = context.renderedPrompt
        var loopPromptHistoryUpdate = context.promptHistoryUpdate
        var modelRoundIndex = 0
        var terminalContext = context

        scheduleAgentActivity(
            AgentActivity(
                kind: .turnStarted,
                timelineID: context.timelineID,
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
                context: turnContext
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
                        decision: .failed(
                            because: error,
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

        logger.warning("Max model rounds (\(context.maxModelRounds)) reached for timeline \(context.timelineID)", metadata: [
            LogKeys.timelineID: .string(context.timelineID.uuidString),
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

private extension TurnLoop {
    private func runOneTurn(
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation,
        context: TurnContext
    ) async -> LoopContinuation {
        let sid = context.timelineID.uuidString.prefix(8).lowercased()
        let turnLabel = "\(context.modelRoundIndex)"
        logger.info("Starting turn \(turnLabel) for timeline \(sid)")

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
            // success, so `commitTerminal` attaches whatever partial assistant text/thinking (and
            // any accumulated tool calls) the user already watched stream in, tagged `.cancelled`,
            // to the same terminal transaction below (see `completeTerminalOutcome`). The cancel
            // event is still surfaced below — the UI needs it (STAB-5 handles retry separately).
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
                LogKeys.timelineID: .string(context.timelineID.uuidString),
                LogKeys.turnID: .string(context.turnID.uuidString),
                LogKeys.requestID: .string(context.requestId.uuidString),
                LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
            ])
            // STAB-1: same data-loss fix for the failure path (network drop, provider 4xx/5xx,
            // idle timeout). A stage-thrown `CancellationError` is wrapped by `Pipeline` as
            // `PipelineError.stageFailed` and lands here — unwrap it so a mid-stream
            // cancellation is still tagged `.cancelled` rather than `.partial` (`commitTerminal`
            // derives the same tag from this outcome below). The error event is still surfaced to
            // the UI (re-thrown below); STAB-5 handles retry separately.
            let isCancellation = Self.isCancellationOrigin(error)
            await commitTerminal(
                decision: isCancellation
                    ? TerminalDecision(
                        outcome: .cancelled(reason: "Turn task cancelled."),
                        delivery: .none,
                        streamError: error
                    )
                    : .failed(because: error, streamError: error),
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
    private func handleToolCallsAfterTurn(
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws -> LoopContinuation {
        let result = try await dependencies.toolRouter.processToolCalls(
            outputs: context.outputs,
            timelineId: context.timelineID,
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
            LogKeys.timelineID: .string(context.timelineID.uuidString),
            LogKeys.turnID: .string(context.turnID.uuidString),
            LogKeys.requestID: .string(context.requestId.uuidString),
            LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
        ]
        if !result.hadToolCalls {
            logger.debug("Turn \(context.modelRoundIndex): no tool calls; assistant content chars=\(contentChars)", metadata: turnMeta)
            return .completed
        }
        if result.hasPersistenceFailure {
            logger.debug("Turn \(context.modelRoundIndex): tool result persistence failed; stopping before follow-up", metadata: turnMeta)
            return .persistenceFailed
        }
        if result.hasDeferred {
            logger.debug("Turn \(context.modelRoundIndex): tool calls deferred for external execution", metadata: turnMeta)
            return .deferredExternally
        }
        logger.debug("Turn \(context.modelRoundIndex): \(result.resolvedToolParams.count) tool-result message(s) to feed back; assistant content chars=\(contentChars)", metadata: turnMeta)
        return .continueWith(result.resolvedToolParams)
    }

    private func processTurn(
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws {
        let pipeline = TurnPipelineBuilder.makePipeline(
            llmService: dependencies.llmService,
            runtimeRepository: dependencies.runtimeRepository,
            streamTimeout: dependencies.policy.streamTimeout,
            clock: dependencies.policy.clock,
            diagnosticSnapshotConfiguration: dependencies.policy.diagnosticSnapshotConfiguration,
            loggingConfiguration: dependencies.policy.loggingConfiguration,
            additionalStages: additionalStages
        )
        let stream = pipeline.execute(context)
        for try await event in stream {
            continuation.yield(event)
        }
    }

    /// Starts best-effort activity delivery without putting provider execution behind a host sink.
    private func scheduleAgentActivity(_ activity: AgentActivity, context: TurnContext) {
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

private extension TurnLoop {
    /// Builds the terminal snapshot and hands it to the runtime-owned finalizer.
    ///
    /// The finalizer is not this Turn task, so cancelling the Turn cannot cancel its commit, and
    /// this task does not wait on the store. The durable commit, sinks, and consumer-facing
    /// terminal signal all happen in the finalizer, in the order `commitTerminal` used to apply
    /// them (ADR 0010).
    private func commitTerminal(
        decision: TerminalDecision,
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async {
        let commit = await makeTerminalCommit(
            decision: decision,
            context: context,
            continuation: continuation
        )
        await dependencies.finalizer.submit(commit)
    }

    private func makeTerminalCommit(
        decision: TerminalDecision,
        context: TurnContext,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async -> TerminalCommit {
        let partialMessage: TimelineMessage?
        switch decision.outcome {
        case .cancelled, .failed:
            // STAB-1: attach whatever partial assistant text/thinking/tool calls the user
            // already watched stream in to the same terminal transaction (ADR 0003, ADR 0007),
            // instead of persisting it with a separate `saveMessage` call before terminal
            // completion — a crash between the two used to leave that row on a Timeline whose
            // Turn was still active.
            let status: Message.MessageStatus = {
                if case .cancelled = decision.outcome { return .cancelled }
                return .partial
            }()
            partialMessage = await PartialAssistantPersistence().partialAssistantMessage(
                context: context,
                status: status
            )
        case .completed, .interrupted:
            partialMessage = nil
        }

        let sidecarCompletion: SidecarCompletion?
        if context.sidecarCommitPolicy == .terminalModelRound {
            let results = await context.outputs.sidecarResults
            sidecarCompletion = results.isEmpty ? nil : SidecarCompletion(
                identity: TurnIdentity(
                    turnID: context.turnID,
                    requestID: context.requestId,
                    modelRoundIndex: max(context.modelRoundIndex - 1, 0)
                ),
                results: results
            )
        } else {
            sidecarCompletion = nil
        }

        return TerminalCommit(
            turnID: context.turnID,
            timelineID: context.timelineID,
            requestID: context.requestId,
            outcome: decision.outcome,
            terminalHandle: TurnTerminalHandle(turnID: context.turnID),
            terminalAssistantMessage: await context.outputs.terminalAssistantMessage,
            partialMessage: partialMessage,
            metadata: await context.outputs.terminalCompletionMetadata,
            sidecarCompletion: sidecarCompletion,
            agentID: context.agentId,
            executionKind: context.executionKind,
            modelRoundIndex: context.modelRoundIndex,
            requestedDelivery: mapDelivery(decision.delivery),
            streamFailure: decision.streamError,
            continuation: continuation
        )
    }

    private func mapDelivery(_ delivery: TerminalDecision.Delivery) -> TerminalCommit.Delivery {
        switch delivery {
        case .none:
            return .none
        case .completion:
            return .completion
        case let .event(event):
            return .event(event)
        }
    }
}
