import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Carries a terminal stream error across the finalizer boundary.
///
/// A `Turn`'s terminal stream error comes from an arbitrary throwing provider or pipeline path, so
/// the concrete type is not statically `Sendable`. The value is write-once, read-only after the
/// Turn loop hands it off, and never shared mutably, so passing it to the detached finalizer task
/// is safe. See `docs/Concurrency/exception-manifest.md`.
struct TerminalStreamFailure: @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- write-once terminal stream error (see docs/Concurrency/exception-manifest.md)
    let error: any Error
}

/// The single terminal intent a Turn loop hands to the finalizer.
///
/// It carries the outcome, how the final durable message is resolved, and the consumer-facing
/// delivery. It deliberately excludes Workspace, tool, and Timeline-cache state: the finalizer must
/// be able to finish a Turn after its Timeline has been evicted and its ephemeral workspace
/// removed.
struct TerminalCommit: Sendable {
    /// The consumer-facing terminal signal for this outcome.
    enum Delivery: Sendable {
        case none
        case completion
        case event(TurnEvent)
    }

    /// How the finalizer resolves the durable final assistant message for this outcome.
    enum FinalMessage: Sendable {
        /// A completed Turn whose terminal assistant row was captured at hand-off.
        case terminalAssistantMessage(TimelineMessage)
        /// A completed Turn with no captured row: fall back to the last durable assistant message
        /// after the caller's input.
        case lastDurableAssistantMessage
        /// A cancelled or failed Turn: resolve a partial row from the captured outputs.
        case partialAssistant(PartialAssistantSource)
        /// Record no final message.
        case none
    }

    let turnID: UUID
    let timelineID: UUID
    let requestID: UUID
    let outcome: TurnOutcome
    let finalMessage: FinalMessage
    let delivery: Delivery
    let terminalHandle: TurnTerminalHandle
    let metadata: LLMResponse?
    /// The terminal sidecar completion event to emit for a completed Turn, when the Turn produced
    /// sidecars under `.terminalModelRound`.
    let sidecarCompletion: SidecarCompletion?
    let agentID: UUID?
    let executionKind: TurnExecutionKind
    let modelRoundIndex: Int
    let streamFailure: TerminalStreamFailure?
    let continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation // swiftlint:disable:this concurrency_stored_continuation -- terminal hand-off owned by the runtime finalizer (see docs/Concurrency/exception-manifest.md)
}

/// The captured outputs a non-completed Turn needs so the finalizer can resolve its partial
/// assistant row without the live `TurnContext`.
///
/// The loop captures this at hand-off. It holds only the assistant row builder's material, never
/// Workspace, tool, or Timeline-cache state, so the finalizer survives Timeline eviction.
struct PartialAssistantSource: Sendable {
    /// Whether the complete assistant row was already accepted by the message store.
    let responseIsDurable: Bool
    /// A complete assistant row a prior stage built and deferred to the terminal transaction.
    let terminalMessage: TimelineMessage?
    /// The material for a partial row, or `nil` when the Turn emitted nothing worth recording.
    let material: AssistantRowMaterial?
}

extension PartialAssistantSource {
    /// Captures the partial-row inputs from a Turn's live outputs at terminal hand-off.
    ///
    /// The threshold is unchanged from the pre-finalizer path: a row is built only when the Turn
    /// emitted assistant text, thinking, audio, or accumulated tool calls, so a spurious empty
    /// assistant row never misrepresents the Turn.
    static func capture(from context: TurnContext) async -> PartialAssistantSource {
        let responseIsDurable = await context.outputs.assistantResponseDurable
        let terminalMessage = await context.outputs.terminalAssistantMessage
        let fullResponse = await context.outputs.fullResponse
        let fullThinking = await context.outputs.fullThinking
        let hasAudio = await !context.outputs.audioData.isEmpty
        let hasToolCalls = await !context.outputs.toolCallAccumulators.isEmpty
        let hasContent = !fullResponse.isEmpty || !fullThinking.isEmpty || hasAudio || hasToolCalls
        let material = hasContent
            ? await MessagePersistenceStage.assistantRowMaterial(
                from: context,
                hasPendingToolCalls: hasToolCalls,
                logger: Logger.module(named: "turn-finalizer")
            )
            : nil
        return PartialAssistantSource(
            responseIsDurable: responseIsDurable,
            terminalMessage: terminalMessage,
            material: material
        )
    }
}

/// Runtime-owned executor for terminal Turn commits (ADR 0010).
///
/// A Turn loop hands its terminal decision here and returns. Because the finalizer is not the
/// cancelled Turn task, cancelling a Turn cannot cancel its commit. Because its work is detached
/// from the Turn task, a store call that hangs bounds how long a Timeline stays busy, not how long
/// eviction takes.
///
/// A commit's own durable write, sinks, and terminal signal run in that order. Commits are
/// deliberately **not** serialized per Timeline. Two commits for one Timeline can be in flight at
/// once, but only after a predecessor stalls past `terminalCommitStallLimit`: admission then
/// interrupts that Turn and admits its successor, whose commit runs while the stalled one is still
/// writing. This needs no cross-Turn serialization. A Turn is only admitted after its predecessor
/// is terminal in the store, and `completeTurn` is first-writer-wins, so a late commit for an
/// interrupted predecessor returns the interrupted record unchanged and can never poison later
/// commits on the same Timeline. ADR 0010 records this guarantee.
actor TurnFinalizer {
    private let repository: any TimelineRuntimeRepository
    private let agentActivitySink: any AgentActivitySink?
    private let turnOutcomeSink: any TurnOutcomeSink?
    private let clock: any RuntimeClock
    private let logger = Logger.module(named: "turn-finalizer")

    /// When a Turn's terminal commit was handed off, keyed by Turn. Used by liveness
    /// classification to bound how long a Timeline stays busy for a stalled commit.
    private var pendingSince: [UUID: ContinuousClock.Instant] = [:]

    /// The commit task for each handed-off Turn, keyed by Turn, so ephemeral Timeline cleanup
    /// can join a commit that is still writing before it deletes the Timeline.
    private struct PendingCommit: Sendable {
        let timelineID: UUID
        let task: Task<Void, Never> // swiftlint:disable:this concurrency_stored_task -- owned by actor (see docs/Concurrency/exception-manifest.md)
    }

    private var pendingCommits: [UUID: PendingCommit] = [:]

    init(
        repository: any TimelineRuntimeRepository,
        agentActivitySink: any AgentActivitySink?,
        turnOutcomeSink: any TurnOutcomeSink?,
        clock: any RuntimeClock
    ) {
        self.repository = repository
        self.agentActivitySink = agentActivitySink
        self.turnOutcomeSink = turnOutcomeSink
        self.clock = clock
    }

    /// Enqueues a terminal commit and returns without waiting for it.
    ///
    /// The commit runs in an unstructured task that is never cancelled by the Turn's cancellation.
    /// The task inherits this actor's isolation and task-locals but not the caller's cancellation,
    /// so a submitted commit always finishes even if the runtime is released before the store
    /// returns. Actor isolation serializes each commit's entry, not its whole duration: `perform`
    /// suspends on the store, so commits for different Turns can overlap (see the ordering note
    /// above).
    func submit(_ commit: TerminalCommit) {
        pendingSince[commit.turnID] = clock.now()
        let turnID = commit.turnID
        let timelineID = commit.timelineID
        let task = Task {
            await self.perform(commit)
            self.clearPending(turnID: turnID)
        }
        pendingCommits[turnID] = PendingCommit(timelineID: timelineID, task: task)
    }

    /// When the given Turn's terminal commit was handed off, or `nil` if none is pending.
    func pendingCommitStartedAt(turnID: UUID) -> ContinuousClock.Instant? {
        pendingSince[turnID]
    }

    /// Waits for every terminal commit the finalizer is still performing for a Timeline.
    ///
    /// Ephemeral Timeline cleanup joins this before deleting so a Turn that is still completing
    /// is never deleted out from under its own terminal commit.
    func awaitPendingCommits(forTimeline timelineID: UUID) async {
        let tasks = pendingCommits.values
            .filter { $0.timelineID == timelineID }
            .map(\.task)
        for task in tasks {
            await task.value
        }
    }

    private func clearPending(turnID: UUID) {
        pendingSince.removeValue(forKey: turnID)
        pendingCommits.removeValue(forKey: turnID)
    }

    // MARK: - Commit

    private func perform(_ commit: TerminalCommit) async {
        let durableOutcome: TurnOutcome
        do {
            durableOutcome = try await completeTerminalOutcome(commit)
        } catch {
            logger.error("Unable to durably record terminal Turn outcome: \(error)")
            commit.continuation.yield(.durabilityFailure(error))
            commit.continuation.finish()
            return
        }

        await emitTerminalSinks(commit: commit, outcome: durableOutcome)

        let usesRequestedOutcome = durableOutcome == commit.outcome
        let delivery = usesRequestedOutcome
            ? commit.delivery
            : Self.delivery(for: durableOutcome)
        switch delivery {
        case .none:
            break
        case let .event(event):
            commit.continuation.yield(event)
        case .completion:
            if let sidecarCompletion = commit.sidecarCompletion {
                commit.continuation.yield(.sidecarsCompleted(sidecarCompletion))
            }
            if case let .terminalAssistantMessage(message) = commit.finalMessage {
                commit.continuation.yield(.generationCompleted(
                    message: message.toMessage(),
                    metadata: commit.metadata ?? LLMResponse()
                ))
            } else {
                commit.continuation.yield(.completedEmpty(finishReason: commit.metadata?.finishReason))
            }
        }

        if usesRequestedOutcome, let failure = commit.streamFailure {
            commit.continuation.finish(throwing: failure.error)
        } else {
            commit.continuation.finish()
        }
    }

    /// Commits the outcome with the finalizer-resolved final message.
    private func completeTerminalOutcome(_ commit: TerminalCommit) async throws -> TurnOutcome {
        let finalMessage = try await resolveFinalMessage(commit)
        let record = try await repository.completeTurn(
            turnID: commit.turnID,
            outcome: commit.outcome,
            finalMessage: finalMessage,
            terminalHandle: commit.terminalHandle,
            now: Date()
        )
        guard let persistedOutcome = record.outcome else {
            throw TurnFinalizerError.missingOutcome(commit.turnID)
        }
        return persistedOutcome
    }

    /// The one place a terminal assistant message is resolved: a captured complete row, a
    /// durable-history fallback for a completed Turn, or a partial row built from captured outputs
    /// for a cancelled or failed one.
    private func resolveFinalMessage(_ commit: TerminalCommit) async throws -> TimelineMessage? {
        switch commit.finalMessage {
        case let .terminalAssistantMessage(message):
            return message
        case .lastDurableAssistantMessage:
            let messages = try await repository.fetchMessages(for: commit.timelineID)
            let userIndex = messages.firstIndex(where: { $0.id == commit.requestID })
            return userIndex.flatMap { index in
                messages.dropFirst(index + 1).last(where: {
                    $0.role == Message.MessageRole.assistant.rawValue
                })
            }
        case let .partialAssistant(source):
            guard !source.responseIsDurable else { return nil }
            if let terminalMessage = source.terminalMessage { return terminalMessage }
            guard let material = source.material else { return nil }
            let status = Self.partialStatus(for: commit.outcome)
            logger.warning(
                "Resolved partial assistant turn for timeline \(commit.timelineID) status=\(status.rawValue) contentChars=\(material.content.text.count) thinkingChars=\(material.thinking.count) toolCalls=\(material.toolCallsJSON != "[]")"
            )
            return MessagePersistenceStage.buildAssistantMessage(from: material, status: status)
        case .none:
            return nil
        }
    }

    /// The status tag a partial row carries for a non-completed outcome.
    private static func partialStatus(for outcome: TurnOutcome) -> Message.MessageStatus {
        if case .cancelled = outcome { return .cancelled }
        return .partial
    }

    private func emitTerminalSinks(commit: TerminalCommit, outcome: TurnOutcome) async {
        await emitAgentActivity(
            AgentActivity(
                kind: Self.activityKind(for: outcome),
                timelineID: commit.timelineID,
                turnID: commit.turnID,
                requestID: commit.requestID,
                agentID: commit.agentID,
                modelRoundIndex: commit.modelRoundIndex,
                detail: Self.outcomeDescription(outcome)
            ),
            turnID: commit.turnID
        )
        await emitTurnOutcome(
            TurnOutcomeRecord(
                timelineID: commit.timelineID,
                turnID: commit.turnID,
                requestID: commit.requestID,
                agentID: commit.agentID,
                executionKind: commit.executionKind,
                modelRoundIndex: commit.modelRoundIndex,
                outcome: outcome
            ),
            turnID: commit.turnID
        )
    }

    private static func activityKind(for outcome: TurnOutcome) -> AgentActivity.Kind {
        switch outcome {
        case .completed:
            return .turnFinished
        case .cancelled:
            return .turnCancelled
        case .failed, .interrupted:
            return .turnFailed
        }
    }

    private static func outcomeDescription(_ outcome: TurnOutcome) -> String {
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

    private func emitAgentActivity(_ activity: AgentActivity, turnID: UUID) async {
        guard let agentActivitySink else { return }
        do {
            try await agentActivitySink.record(activity)
        } catch {
            await persistNotice(
                code: .agentActivitySinkFailed,
                turnID: turnID,
                message: ErrorKit.userFriendlyMessage(for: error)
            )
        }
    }

    private func emitTurnOutcome(_ outcome: TurnOutcomeRecord, turnID: UUID) async {
        guard let turnOutcomeSink else { return }
        do {
            try await turnOutcomeSink.record(outcome)
        } catch {
            await persistNotice(
                code: .turnOutcomeSinkFailed,
                turnID: turnID,
                message: ErrorKit.userFriendlyMessage(for: error)
            )
        }
    }

    private func persistNotice(code: TurnNoticeCode, turnID: UUID, message: String) async {
        do {
            try await repository.appendNotice(
                turnID: turnID,
                notice: TurnNotice(kind: code.rawValue, message: message)
            )
        } catch {
            logger.error("Unable to persist runtime customization notice: \(error)")
        }
    }

    static func delivery(for outcome: TurnOutcome) -> TerminalCommit.Delivery {
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

private enum TurnFinalizerError: Error, Sendable {
    case missingOutcome(UUID)
}
