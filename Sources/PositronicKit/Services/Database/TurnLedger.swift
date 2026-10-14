import Foundation
import PKContracts
import PKUtilities

// MARK: - Turn ledger

/// The runtime-owned decision module for every durable Turn transition.
///
/// A repository adapter does three things and nothing more: it loads a ``TurnLedgerSnapshot``
/// for one Timeline (or one Turn), passes the caller's intent to a `TurnLedger.decide…`
/// function, and applies the returned ``TurnLedgerCommit`` inside one storage transaction.
/// Admission idempotency by Request ID, busy and quarantine rejection, the tool-result barrier,
/// ordered message membership, first-writer-wins terminal commits, and append-only history are
/// decided here once, not re-implemented per adapter.
///
/// The decisions are pure: they read the snapshot, never touch an actor or a database, and either
/// return the exact rows to write or throw a ``TimelineRuntimeRepositoryError``.
package enum TurnLedger {
    // MARK: Admission

    /// Decides one admission transaction.
    ///
    /// Returns a `.joined` or `.replayed` admission with an empty commit when the Request ID is
    /// already known; otherwise returns the new ``TurnRecord`` plus the rows that make the Turn,
    /// its active pointer, and its input message visible together.
    package static func decideAdmission(
        snapshot: TurnLedgerSnapshot,
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) throws -> TurnLedgerDecision<TurnAdmission> {
        guard snapshot.timelineExists else {
            throw TimelineRuntimeRepositoryError.timelineNotFound(timelineID)
        }
        if let inputMessage, inputMessage.timelineID != timelineID {
            throw TimelineRuntimeRepositoryError.inputMessageTimelineMismatch(
                messageID: inputMessage.id,
                expectedTimelineID: timelineID,
                actualTimelineID: inputMessage.timelineID
            )
        }

        let callerIntent = TurnCallerIntent(requestID: requestID, fingerprint: callerIntentFingerprint)
        let matching = snapshot.turns
            .filter { $0.callerIntent.requestID == requestID }
            .max { $0.createdAt < $1.createdAt }
        var retryRelation: TurnRetryRelation?
        if let matching {
            if matching.callerIntent.fingerprint == callerIntentFingerprint, !matching.isTerminal {
                return TurnLedgerDecision(result: TurnAdmission(disposition: .joined, turn: matching))
            }
            if matching.callerIntent.fingerprint == callerIntentFingerprint,
               isCompleted(matching.outcome)
            {
                return TurnLedgerDecision(result: TurnAdmission(disposition: .replayed, turn: matching))
            }
            if matching.isQuarantined {
                // A quarantined Timeline rejects admission until an operator releases it; the
                // original Request ID may not be replayed while the side effect is unreconciled.
                throw TimelineRuntimeRepositoryError.timelineQuarantined(
                    timelineID: timelineID,
                    turnID: matching.identity.turnID
                )
            }
            // A failed/cancelled/interrupted attempt may be retried with the same Request ID,
            // whether the retry repeats the exact input or supplies changed tool outputs. The
            // retry is a new durable Turn linked to the failed attempt; completed Turns and
            // active attempts remain strict idempotency conflicts.
            guard matching.isTerminal,
                  !isCompleted(matching.outcome)
            else {
                throw TimelineRuntimeRepositoryError.idempotencyConflict(requestID: requestID)
            }
            retryRelation = TurnRetryRelation(
                retriedTurnID: matching.identity.turnID,
                attempt: (matching.retryRelation?.attempt ?? 0) + 1
            )
        }

        if let quarantineTurnID = snapshot.quarantinedTurnID {
            throw TimelineRuntimeRepositoryError.timelineQuarantined(
                timelineID: timelineID,
                turnID: quarantineTurnID
            )
        }
        if let activeTurnID = snapshot.activeTurnID {
            throw TimelineRuntimeRepositoryError.timelineBusy(
                timelineID: timelineID,
                activeTurnID: activeTurnID
            )
        }

        let identity = TurnIdentity(turnID: turnID, requestID: requestID, modelRoundIndex: 0)
        let record = TurnRecord(
            identity: identity,
            timelineID: timelineID,
            callerIntent: callerIntent,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            lifecycle: .admitted,
            notices: [TurnNotice(kind: "turn-admitted", createdAt: now)],
            retryRelation: retryRelation,
            memberMessageIDs: inputMessage.map { [$0.id] } ?? [],
            createdAt: now,
            updatedAt: now
        )

        var commit = TurnLedgerCommit()
        commit.upsertedTurns = [record]
        commit.pointerTimelineID = timelineID
        commit.activeTurnID = turnID
        commit.quarantinedTurnID = snapshot.quarantinedTurnID

        if let inputMessage {
            if let existing = snapshot.message(id: inputMessage.id) {
                // Reusing a durable input is only valid for a retry of the Turn that owns it.
                // Otherwise admission would claim an unrelated writer's existing message.
                guard let matching, retryRelation != nil else {
                    throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: inputMessage.id)
                }
                // Older failed Turns predate membership tracking. Their membership is unknown,
                // so preserve the legacy retry path rather than falsely treating unknown as
                // unowned.
                guard matching.memberMessageIDs == nil
                    || matching.memberMessageIDs?.contains(inputMessage.id) == true
                else {
                    throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: inputMessage.id)
                }
                guard messagesEquivalentIgnoringTimestamp(existing, inputMessage) else {
                    throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: inputMessage.id)
                }
            } else {
                commit.appendedMessages = [inputMessage]
            }
        }

        return TurnLedgerDecision(
            commit: commit,
            result: TurnAdmission(disposition: .admitted, turn: record)
        )
    }

    /// Decides a linked retry admission. Resolves the predecessor before delegating to
    /// ``decideAdmission(snapshot:timelineID:requestID:callerIntentFingerprint:inputMessage:executionKind:capturedAgentID:turnID:now:)``
    /// so a missing predecessor is reported even when the Request ID would join.
    package static func decideAdmitRetry(
        snapshot: TurnLedgerSnapshot,
        timelineID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) throws -> TurnLedgerDecision<TurnAdmission> {
        guard let previous = snapshot.turn(id: previousTurnID), previous.timelineID == timelineID else {
            throw TimelineRuntimeRepositoryError.turnNotFound(previousTurnID)
        }
        let decision = try decideAdmission(
            snapshot: snapshot,
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
        guard decision.result.disposition == .admitted else {
            return decision
        }
        var record = decision.result.turn
        record.retryRelation = TurnRetryRelation(retriedTurnID: previousTurnID, attempt: attempt)
        var commit = decision.commit
        commit.upsertedTurns = [record]
        return TurnLedgerDecision(
            commit: commit,
            result: TurnAdmission(disposition: .admitted, turn: record)
        )
    }

    // MARK: Membership and ordering barriers

    /// Decides the atomic tool-message/result commit, including ordered membership.
    package static func decideRecordTurnMessage(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        message: TimelineMessage
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: turnID, on: message.timelineID)
        if snapshot.hasMessage(id: message.id), turn.memberMessageIDs?.contains(message.id) != true {
            throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
        }
        var commit = TurnLedgerCommit()
        commit.appendedMessages = [message]
        if turn.memberMessageIDs?.contains(message.id) == false {
            turn.memberMessageIDs?.append(message.id)
        }
        commit.upsertedTurns = [turn]
        return TurnLedgerDecision(commit: commit, result: ())
    }

    /// Decides a model-round transition. The tool-result barrier rejects a round that starts
    /// while an earlier round's intent has no durable result.
    package static func decideBeginModelRound(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        modelRoundIndex: Int,
        now: Date
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: turnID)
        let unresolved = snapshot.toolIntents
            .filter { $0.turnID == turnID && $0.modelRoundIndex < modelRoundIndex }
            .first { snapshot.result(turnID: $0.turnID, toolCallID: $0.toolCallID) == nil }
        if let unresolved {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(
                turnID: turnID,
                toolCallID: unresolved.toolCallID
            )
        }
        turn.lifecycle = .running
        turn.currentModelRoundIndex = modelRoundIndex
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "model-round-started", message: "(modelRoundIndex)", createdAt: now))
        return TurnLedgerDecision(commit: TurnLedgerCommit(upsertedTurns: [turn]), result: ())
    }

    /// Decides a provider-request record. The request may only be durable while the Turn is open.
    package static func decideRecordProviderRequest(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        correlation: TurnCorrelation?,
        now: Date
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: turnID)
        turn.lifecycle = .running
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "provider-request-durable", message: "(modelRoundIndex)", createdAt: now))
        if let correlation { turn.correlations.append(correlation) }
        return TurnLedgerDecision(commit: TurnLedgerCommit(upsertedTurns: [turn]), result: ())
    }

    /// Decides a durable tool intent. The intent must not duplicate an existing one.
    package static func decideRecordToolIntent(
        snapshot: TurnLedgerSnapshot,
        intent: RuntimeToolIntent
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: intent.turnID, on: intent.timelineID)
        guard snapshot.intent(turnID: intent.turnID, toolCallID: intent.toolCallID) == nil else {
            throw TimelineRuntimeRepositoryError.duplicateToolIntent(
                turnID: intent.turnID,
                toolCallID: intent.toolCallID
            )
        }
        turn.lifecycle = .awaitingTool
        turn.updatedAt = intent.createdAt
        turn.notices.append(TurnNotice(kind: "tool-intent-durable", message: intent.toolCallID, createdAt: intent.createdAt))
        var commit = TurnLedgerCommit()
        commit.upsertedTurns = [turn]
        commit.upsertedToolIntents = [intent]
        return TurnLedgerDecision(commit: commit, result: ())
    }

    /// Decides a tool result, optionally committing its message in the same transaction.
    package static func decideRecordToolResult(
        snapshot: TurnLedgerSnapshot,
        result: RuntimeToolResult,
        message: TimelineMessage?
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: result.turnID, on: result.timelineID)
        if let message, message.timelineID != result.timelineID {
            throw TimelineRuntimeRepositoryError.invalidTransition(
                turnID: result.turnID,
                lifecycle: turn.lifecycle
            )
        }
        guard snapshot.intent(turnID: result.turnID, toolCallID: result.toolCallID) != nil else {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(
                turnID: result.turnID,
                toolCallID: result.toolCallID
            )
        }
        guard snapshot.result(turnID: result.turnID, toolCallID: result.toolCallID) == nil else {
            throw TimelineRuntimeRepositoryError.duplicateToolResult(
                turnID: result.turnID,
                toolCallID: result.toolCallID
            )
        }
        var commit = TurnLedgerCommit()
        if let message {
            if snapshot.hasMessage(id: message.id), turn.memberMessageIDs?.contains(message.id) != true {
                throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
            }
            commit.appendedMessages = [message]
        }
        if let message, turn.memberMessageIDs?.contains(message.id) == false {
            turn.memberMessageIDs?.append(message.id)
        }
        turn.lifecycle = .running
        turn.updatedAt = result.createdAt
        turn.notices.append(TurnNotice(kind: "tool-result-durable", message: result.toolCallID, createdAt: result.createdAt))
        commit.upsertedTurns = [turn]
        commit.upsertedToolResults = [result]
        return TurnLedgerDecision(commit: commit, result: ())
    }

    // MARK: Terminal transitions and recovery

    /// Decides a terminal commit. First-writer-wins: an already-terminal Turn returns its durable
    /// record with no rows to write.
    package static func decideCompleteTurn(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) throws -> TurnLedgerDecision<TurnRecord> {
        guard var turn = snapshot.turn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        guard !turn.isTerminal else {
            return TurnLedgerDecision(result: turn)
        }
        if case .completed = outcome,
           let pending = firstUnresolvedToolIntent(snapshot: snapshot, turnID: turnID)
        {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(
                turnID: turnID,
                toolCallID: pending.toolCallID
            )
        }
        var commit = TurnLedgerCommit()
        commit.pointerTimelineID = turn.timelineID
        commit.activeTurnID = nil
        commit.quarantinedTurnID = snapshot.quarantinedTurnID
        if let finalMessage {
            guard finalMessage.timelineID == turn.timelineID else {
                throw TimelineRuntimeRepositoryError.finalMessageTimelineMismatch(
                    messageID: finalMessage.id,
                    expectedTimelineID: turn.timelineID,
                    actualTimelineID: finalMessage.timelineID
                )
            }
            // A pre-existing assistant message may be the current Turn's already-recorded
            // intermediate row. Never claim an unrelated writer's row as a new member.
            let alreadyPresent = snapshot.hasMessage(id: finalMessage.id)
            if alreadyPresent, turn.memberMessageIDs?.contains(finalMessage.id) != true {
                throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: finalMessage.id)
            }
            if !alreadyPresent {
                commit.appendedMessages = [finalMessage]
            }
            if !alreadyPresent, turn.memberMessageIDs?.contains(finalMessage.id) == false {
                turn.memberMessageIDs?.append(finalMessage.id)
            }
        }
        turn.outcome = outcome
        turn.lifecycle = lifecycle(for: outcome)
        turn.terminalHandle = terminalHandle
        turn.terminalMessageID = finalMessage?.id
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "turn-terminal", message: terminalMessage(for: outcome), createdAt: now))
        commit.upsertedTurns = [turn]
        return TurnLedgerDecision(commit: commit, result: turn)
    }

    /// Decides an interruption. First-writer-wins against a committed terminal outcome.
    package static func decideInterruptTurn(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) throws -> TurnLedgerDecision<TurnInterruptResult> {
        guard var turn = snapshot.turn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        guard !turn.isTerminal else {
            // First-writer-wins: the Turn's owner already committed a terminal outcome, so the
            // interruption changes nothing and reports the durable record.
            return TurnLedgerDecision(result: .alreadyTerminal(turn))
        }
        turn.outcome = .interrupted(reason: reason)
        turn.lifecycle = .interrupted
        turn.updatedAt = now
        var commit = TurnLedgerCommit()
        commit.pointerTimelineID = turn.timelineID
        commit.activeTurnID = nil
        switch disposition {
        case .retryable:
            turn.quarantine = nil
            // Only clear this Turn's own quarantine marker; a marker for a different Turn (for
            // example one quarantined by `deleteTimeline`) stays until the operator releases it.
            commit.quarantinedTurnID = snapshot.quarantinedTurnID == turnID ? nil : snapshot.quarantinedTurnID
            turn.notices.append(TurnNotice(kind: "turn-interrupted", message: reason, createdAt: now))
        case let .quarantined(message):
            turn.quarantine = TurnQuarantine(reason: message, createdAt: now)
            commit.quarantinedTurnID = turnID
            turn.notices.append(TurnNotice(kind: "turn-quarantined", message: message, createdAt: now))
        }
        commit.upsertedTurns = [turn]
        return TurnLedgerDecision(commit: commit, result: .interrupted(turn))
    }

    /// Decides an operator quarantine release.
    package static func decideReleaseQuarantine(
        snapshot: TurnLedgerSnapshot,
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) throws -> TurnLedgerDecision<TurnRecord> {
        guard confirmation.phrase == QuarantineReleaseConfirmation.requiredPhrase else {
            throw TimelineRuntimeRepositoryError.confirmationRequired
        }
        guard var turn = snapshot.turn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        guard turn.timelineID == timelineID, turn.isQuarantined else {
            throw TimelineRuntimeRepositoryError.quarantineNotFound(timelineID: timelineID, turnID: turnID)
        }
        turn.quarantine = nil
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "turn-quarantine-released", createdAt: now))
        var commit = TurnLedgerCommit()
        commit.upsertedTurns = [turn]
        commit.pointerTimelineID = timelineID
        commit.activeTurnID = snapshot.activeTurnID
        commit.quarantinedTurnID = snapshot.quarantinedTurnID == turnID ? nil : snapshot.quarantinedTurnID
        return TurnLedgerDecision(commit: commit, result: turn)
    }

    // MARK: Host-facing metadata

    /// Decides a notice append. Notices may be recorded after terminal completion so best-effort
    /// customization failures remain observable.
    package static func decideAppendNotice(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        notice: TurnNotice
    ) throws -> TurnLedgerDecision<Void> {
        guard var turn = snapshot.turn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        turn.notices.append(notice)
        turn.updatedAt = notice.createdAt
        return TurnLedgerDecision(commit: TurnLedgerCommit(upsertedTurns: [turn]), result: ())
    }

    /// Decides a correlation append against an open Turn.
    package static func decideAppendCorrelation(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        correlation: TurnCorrelation,
        now: Date
    ) throws -> TurnLedgerDecision<Void> {
        var turn = try openTurn(snapshot: snapshot, turnID: turnID)
        turn.correlations.append(correlation)
        turn.updatedAt = now
        return TurnLedgerDecision(commit: TurnLedgerCommit(upsertedTurns: [turn]), result: ())
    }

    // MARK: Shared predicates

    /// The Turn if it can still transition: it exists, is not terminal, and (when given)
    /// belongs to `timelineID`.
    package static func openTurn(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID,
        on timelineID: UUID? = nil
    ) throws -> TurnRecord {
        guard let turn = snapshot.turn(id: turnID) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        guard !turn.isTerminal, timelineID.map({ $0 == turn.timelineID }) ?? true else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        return turn
    }

    /// Maps a terminal outcome to its lifecycle label.
    package static func lifecycle(for outcome: TurnOutcome) -> TurnLifecycle {
        switch outcome {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        }
    }

    /// Whether an outcome is the successful terminal case.
    package static func isCompleted(_ outcome: TurnOutcome?) -> Bool {
        if case .completed? = outcome { return true }
        return false
    }

    /// The audit notice text for a terminal outcome.
    package static func terminalMessage(for outcome: TurnOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case let .failed(message): return "failed: \(message)"
        case let .cancelled(reason): return "cancelled\(reason.map { ": \($0)" } ?? "")"
        case let .interrupted(reason): return "interrupted: \(reason)"
        }
    }

    /// The earliest unresolved tool intent for a Turn, used by the tool-result barrier.
    package static func firstUnresolvedToolIntent(
        snapshot: TurnLedgerSnapshot,
        turnID: UUID
    ) -> RuntimeToolIntent? {
        snapshot.toolIntents
            .filter { $0.turnID == turnID }
            .sorted { $0.createdAt < $1.createdAt }
            .first { snapshot.result(turnID: turnID, toolCallID: $0.toolCallID) == nil }
    }

    /// Compares two durable messages for append-only equivalence, ignoring their timestamps.
    package static func messagesEquivalentIgnoringTimestamp(
        _ lhs: TimelineMessage,
        _ rhs: TimelineMessage
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.timelineID == rhs.timelineID
            && lhs.role == rhs.role
            && lhs.messageContent == rhs.messageContent
            && lhs.parentID == rhs.parentID
            && lhs.reasoning == rhs.reasoning
            && lhs.toolCalls == rhs.toolCalls
            && lhs.toolCallID == rhs.toolCallID
            && lhs.agentID == rhs.agentID
            && lhs.executionKind == rhs.executionKind
            && lhs.remoteDepth == rhs.remoteDepth
            && lhs.snapshotData == rhs.snapshotData
            && lhs.status == rhs.status
    }
}

/// The loaded ledger state a single decision reads.
///
/// A Timeline-scoped snapshot carries every Turn and message for one Timeline; a Turn-scoped
/// snapshot additionally carries that Turn's tool intents and results. Both are plain values so
/// the decisions run without an actor or a database.
package struct TurnLedgerSnapshot: Sendable {
    package var timelineExists: Bool
    package var turns: [TurnRecord]
    package var messages: [TimelineMessage]
    package var activeTurnID: UUID?
    package var quarantinedTurnID: UUID?
    package var toolIntents: [RuntimeToolIntent]
    package var toolResults: [RuntimeToolResult]

    package init(
        timelineExists: Bool,
        turns: [TurnRecord] = [],
        messages: [TimelineMessage] = [],
        activeTurnID: UUID? = nil,
        quarantinedTurnID: UUID? = nil,
        toolIntents: [RuntimeToolIntent] = [],
        toolResults: [RuntimeToolResult] = []
    ) {
        self.timelineExists = timelineExists
        self.turns = turns
        self.messages = messages
        self.activeTurnID = activeTurnID
        self.quarantinedTurnID = quarantinedTurnID
        self.toolIntents = toolIntents
        self.toolResults = toolResults
    }

    package func turn(id: UUID) -> TurnRecord? {
        turns.first { $0.identity.turnID == id }
    }

    package func message(id: UUID) -> TimelineMessage? {
        messages.first { $0.id == id }
    }

    package func hasMessage(id: UUID) -> Bool {
        message(id: id) != nil
    }

    package func intent(turnID: UUID, toolCallID: String) -> RuntimeToolIntent? {
        toolIntents.first { $0.turnID == turnID && $0.toolCallID == toolCallID }
    }

    package func result(turnID: UUID, toolCallID: String) -> RuntimeToolResult? {
        toolResults.first { $0.turnID == turnID && $0.toolCallID == toolCallID }
    }
}

/// The exact rows a decision says to write, applied by the adapter in one transaction.
package struct TurnLedgerCommit: Sendable {
    package var upsertedTurns: [TurnRecord]
    package var appendedMessages: [TimelineMessage]
    package var upsertedToolIntents: [RuntimeToolIntent]
    package var upsertedToolResults: [RuntimeToolResult]
    /// When set, the Timeline whose active and quarantine pointers this commit rewrites.
    package var pointerTimelineID: UUID?
    package var activeTurnID: UUID?
    package var quarantinedTurnID: UUID?

    package init(
        upsertedTurns: [TurnRecord] = [],
        appendedMessages: [TimelineMessage] = [],
        upsertedToolIntents: [RuntimeToolIntent] = [],
        upsertedToolResults: [RuntimeToolResult] = [],
        pointerTimelineID: UUID? = nil,
        activeTurnID: UUID? = nil,
        quarantinedTurnID: UUID? = nil
    ) {
        self.upsertedTurns = upsertedTurns
        self.appendedMessages = appendedMessages
        self.upsertedToolIntents = upsertedToolIntents
        self.upsertedToolResults = upsertedToolResults
        self.pointerTimelineID = pointerTimelineID
        self.activeTurnID = activeTurnID
        self.quarantinedTurnID = quarantinedTurnID
    }
}

/// A decision result paired with the rows to write.
package struct TurnLedgerDecision<Result: Sendable>: Sendable {
    package let commit: TurnLedgerCommit
    package let result: Result

    package init(commit: TurnLedgerCommit = TurnLedgerCommit(), result: Result) {
        self.commit = commit
        self.result = result
    }
}
