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

/// A terminal decision and the snapshot a finalizer needs to record and deliver it.
///
/// The Turn loop builds this from its own context and hands it off. It deliberately excludes
/// Workspace, tool, and Timeline-cache state: the finalizer must be able to finish a Turn after
/// its Timeline has been evicted and its ephemeral workspace removed.
struct TerminalCommit: Sendable {
    enum Delivery: Sendable {
        case none
        case completion
        case event(TurnEvent)
    }

    let turnID: UUID
    let timelineID: UUID
    let requestID: UUID
    let outcome: TurnOutcome
    let terminalHandle: TurnTerminalHandle
    let terminalAssistantMessage: TimelineMessage?
    let partialMessage: TimelineMessage?
    let metadata: APIResponseMetadata?
    /// The terminal sidecar completion event to emit for a completed Turn, when the Turn produced
    /// sidecars under `.terminalModelRound`.
    let sidecarCompletion: SidecarCompletion?
    let agentID: UUID?
    let executionKind: TurnExecutionKind
    let modelRoundIndex: Int
    let requestedDelivery: Delivery
    let streamFailure: TerminalStreamFailure?
    let continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation // swiftlint:disable:this concurrency_stored_continuation -- terminal hand-off owned by the runtime finalizer (see docs/Concurrency/exception-manifest.md)
}

/// Runtime-owned executor for terminal Turn commits (ADR 0010).
///
/// A Turn loop hands its terminal decision here and returns. Because the finalizer is not the
/// cancelled Turn task, cancelling a Turn cannot cancel its commit. Because its work is detached
/// from the Turn task, a store call that hangs bounds how long a Timeline stays busy, not how long
/// eviction takes.
///
/// Commits run independently per Turn. Durable writes need no further serialization: a Turn is
/// only admitted after its predecessor is terminal in the store, and `completeTurn` is
/// first-writer-wins, so a commit that hangs can never poison later commits on the same Timeline.
actor TurnFinalizer {
    private let repository: any TimelineRuntimeRepository
    private let agentActivitySink: (any AgentActivitySink)?
    private let turnOutcomeSink: (any TurnOutcomeSink)?
    private let clock: any RuntimeClock
    private let logger = Logger.module(named: "turn-finalizer")

    /// When a Turn's terminal commit was handed off, keyed by Turn. Used by liveness
    /// classification to bound how long a Timeline stays busy for a stalled commit.
    private var pendingSince: [UUID: ContinuousClock.Instant] = [:]

    init(
        repository: any TimelineRuntimeRepository,
        agentActivitySink: (any AgentActivitySink)?,
        turnOutcomeSink: (any TurnOutcomeSink)?,
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
    /// and it holds the actor until the commit completes, so a submitted commit always finishes
    /// even if the runtime is released before the store returns.
    func submit(_ commit: TerminalCommit) {
        pendingSince[commit.turnID] = clock.now()
        let turnID = commit.turnID
        Task {
            await self.perform(commit)
            await self.clearPending(turnID: turnID)
        }
    }

    /// When the given Turn's terminal commit was handed off, or `nil` if none is pending.
    func pendingCommitStartedAt(turnID: UUID) -> ContinuousClock.Instant? {
        pendingSince[turnID]
    }

    private func clearPending(turnID: UUID) {
        pendingSince.removeValue(forKey: turnID)
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
            ? commit.requestedDelivery
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
            if let message = commit.terminalAssistantMessage {
                commit.continuation.yield(.generationCompleted(
                    message: message.toMessage(),
                    metadata: commit.metadata ?? APIResponseMetadata()
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

    /// Resolves the final message and commits the outcome. A completed Turn without a captured
    /// assistant row falls back to the last durable assistant message after the caller's input.
    private func completeTerminalOutcome(_ commit: TerminalCommit) async throws -> TurnOutcome {
        let finalMessage: TimelineMessage?
        switch commit.outcome {
        case .completed:
            if let terminalAssistantMessage = commit.terminalAssistantMessage {
                finalMessage = terminalAssistantMessage
            } else {
                let messages = try await repository.fetchMessages(for: commit.timelineID)
                let userIndex = messages.firstIndex(where: { $0.id == commit.requestID })
                finalMessage = userIndex.flatMap { index in
                    messages.dropFirst(index + 1).last(where: {
                        $0.role == Message.MessageRole.assistant.rawValue
                    })
                }
            }
        case .cancelled, .failed:
            finalMessage = commit.partialMessage
        case .interrupted:
            finalMessage = nil
        }

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
