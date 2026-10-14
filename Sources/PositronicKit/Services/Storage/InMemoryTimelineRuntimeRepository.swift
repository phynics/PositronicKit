import Foundation
import PKContracts
import PKUtilities

/// An actor-backed reference implementation of ``TimelineRuntimeRepository``.
///
/// The actor gives tests and local hosts one serialization boundary. The transition rules
/// themselves live in ``TurnLedger``: each method loads a ``TurnLedgerSnapshot``, asks the ledger
/// for a decision, and applies the returned ``TurnLedgerCommit`` without an actor suspension, so
/// the snapshot and the commit are one actor-isolated transition. A database-backed adapter
/// implements the same shape against a storage transaction.
public actor InMemoryTimelineRuntimeRepository: TimelineRuntimeRepository, WorkspaceBindingRepository {
    private struct ToolKey: Hashable {
        let turnID: UUID
        let toolCallID: String
    }

    private var timelines: [UUID: TimelineRecord] = [:]
    private var messages: [UUID: [TimelineMessage]] = [:]
    private var turns: [UUID: TurnRecord] = [:]
    private var activeTurns: [UUID: UUID] = [:]
    private var quarantinedTurns: [UUID: UUID] = [:]
    private var intents: [ToolKey: RuntimeToolIntent] = [:]
    private var results: [ToolKey: RuntimeToolResult] = [:]
    private var workspaceBindings = WorkspaceBindingTable()
    private let durable: Bool

    public nonisolated var isDurable: Bool {
        durable
    }

    /// - Parameter isDurable: What this store reports through ``DurabilityAware/isDurable``.
    ///   Defaults to `false`, since an in-memory repository does not survive process restart; pass
    ///   `true` only in tests that need a store which classifies as durable in a
    ///   ``PKRuntime/DurabilityReport``.
    public init(isDurable: Bool = false) {
        durable = isDurable
    }

    // MARK: TimelinePersistenceProtocol

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        timelines[timeline.id] = timeline
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        timelines[id]
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        timelines.values
            .filter { includeArchived || !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelines.removeValue(forKey: id)
        // Cascade: destroying the Timeline destroys its history. Append-only means "immutable
        // while the Timeline lives," not "retained forever" — once the Timeline row is gone, its
        // messages become unreachable, so this conformer removes them
        // here rather than leaving them as an orphaned, unbounded leak. See the cascade contract
        // documented on `TimelineRuntimeRepository`.
        messages.removeValue(forKey: id)
        workspaceBindings.removeAll(for: id)
        if let activeTurnID = activeTurns.removeValue(forKey: id) {
            turns[activeTurnID]?.quarantine = TurnQuarantine(
                reason: "Timeline deleted while Turn was active."
            )
            quarantinedTurns[id] = activeTurnID
        }
    }

    // MARK: TimelineMessageStoreProtocol

    public func saveMessage(_ message: TimelineMessage) async throws {
        try appendMessage(message)
    }

    /// Appends a message without an actor suspension. Admission uses this helper so the input
    /// message and Turn record become visible as one actor-isolated transition.
    private func appendMessage(_ message: TimelineMessage) throws {
        var history = messages[message.timelineID, default: []]
        if let existing = history.first(where: { $0.id == message.id }) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let existingData = try encoder.encode(existing)
            let newData = try encoder.encode(message)
            guard existingData == newData else {
                throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
            }
            return
        }
        history.append(message)
        messages[message.timelineID] = history
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        messages[timelineID, default: []].chronological()
    }

    // MARK: Admission

    public func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        let decision = try TurnLedger.decideAdmission(
            snapshot: ledgerSnapshot(forTimeline: timelineID),
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
        try apply(decision.commit)
        return decision.result
    }

    public func admitRetry(
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
    ) async throws -> TurnAdmission {
        let decision = try TurnLedger.decideAdmitRetry(
            snapshot: ledgerSnapshot(forTimeline: timelineID),
            timelineID: timelineID,
            previousTurnID: previousTurnID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            attempt: attempt,
            now: now
        )
        try apply(decision.commit)
        return decision.result
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        turns[id]
    }

    public func recordTurnMessage(_ message: TimelineMessage, turnID: UUID) async throws {
        let decision = try TurnLedger.decideRecordTurnMessage(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            message: message
        )
        try apply(decision.commit)
    }

    public func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        guard let id = activeTurns[timelineID] else { return nil }
        return turns[id]
    }

    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        let decision = try TurnLedger.decideAppendNotice(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            notice: notice
        )
        try apply(decision.commit)
    }

    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        let decision = try TurnLedger.decideAppendCorrelation(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            correlation: correlation,
            now: now
        )
        try apply(decision.commit)
    }

    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try mutableTurn(turnID).notices
    }

    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try mutableTurn(turnID).correlations
    }

    // MARK: Ordering barriers

    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        let decision = try TurnLedger.decideBeginModelRound(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            now: now
        )
        try apply(decision.commit)
    }

    public func recordProviderRequest(
        turnID: UUID,
        modelRoundIndex _: Int,
        correlation: TurnCorrelation?,
        now: Date
    ) async throws {
        let decision = try TurnLedger.decideRecordProviderRequest(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            correlation: correlation,
            now: now
        )
        try apply(decision.commit)
    }

    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        let decision = try TurnLedger.decideRecordToolIntent(
            snapshot: try ledgerSnapshot(forTurn: intent.turnID),
            intent: intent
        )
        try apply(decision.commit)
    }

    public func recordToolResult(_ result: RuntimeToolResult) async throws {
        try await commitToolResult(result, message: nil)
    }

    public func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
        try await commitToolResult(result, message: message)
    }

    private func commitToolResult(_ result: RuntimeToolResult, message: TimelineMessage?) async throws {
        let decision = try TurnLedger.decideRecordToolResult(
            snapshot: try ledgerSnapshot(forTurn: result.turnID),
            result: result,
            message: message
        )
        try apply(decision.commit)
    }

    public func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] {
        intents.values.filter { $0.turnID == turnID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] {
        results.values.filter { $0.turnID == turnID }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Terminal transitions and recovery

    public func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord {
        let decision = try TurnLedger.decideCompleteTurn(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            outcome: outcome,
            finalMessage: finalMessage,
            terminalHandle: terminalHandle,
            now: now
        )
        try apply(decision.commit)
        return decision.result
    }

    public func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult {
        let decision = try TurnLedger.decideInterruptTurn(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            turnID: turnID,
            reason: reason,
            disposition: disposition,
            now: now
        )
        try apply(decision.commit)
        return decision.result
    }

    public func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord {
        let decision = try TurnLedger.decideReleaseQuarantine(
            snapshot: try ledgerSnapshot(forTurn: turnID),
            timelineID: timelineID,
            turnID: turnID,
            confirmation: confirmation,
            now: now
        )
        try apply(decision.commit)
        return decision.result
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        try workspaceBindings.claim(workspaceID: workspaceID, for: timelineID, now: now)
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now _: Date = Date()
    ) async throws {
        try workspaceBindings.release(workspaceID: workspaceID, from: timelineID)
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        try workspaceBindings.transfer(
            workspaceID: workspaceID,
            from: sourceTimelineID,
            to: destinationTimelineID,
            now: now
        )
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        workspaceBindings.bindings(for: timelineID)
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        workspaceBindings.timelineID(for: workspaceID)
    }

    // MARK: Ledger adapter

    /// Loads the Timeline-scoped ledger snapshot: every Turn and message for the Timeline plus
    /// its active and quarantine pointers.
    private func ledgerSnapshot(forTimeline timelineID: UUID) -> TurnLedgerSnapshot {
        TurnLedgerSnapshot(
            timelineExists: timelines[timelineID] != nil,
            turns: turns.values.filter { $0.timelineID == timelineID },
            messages: messages[timelineID, default: []],
            activeTurnID: activeTurns[timelineID],
            quarantinedTurnID: quarantinedTurns[timelineID]
        )
    }

    /// Loads the Turn-scoped ledger snapshot. The Turn must already exist, so its Timeline is
    /// known before the load. The ledger compares any caller-supplied Timeline and reports a
    /// mismatch, so the snapshot is always scoped to the Turn's own Timeline.
    private func ledgerSnapshot(forTurn turnID: UUID) throws -> TurnLedgerSnapshot {
        guard let turn = turns[turnID] else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        let scope = turn.timelineID
        return TurnLedgerSnapshot(
            timelineExists: timelines[scope] != nil,
            turns: turns.values.filter { $0.timelineID == scope },
            messages: messages[scope, default: []],
            activeTurnID: activeTurns[scope],
            quarantinedTurnID: quarantinedTurns[scope],
            toolIntents: intents.values.filter { $0.turnID == turnID },
            toolResults: results.values.filter { $0.turnID == turnID }
        )
    }

    /// Applies one ledger commit without an actor suspension. The ledger has already validated
    /// append-only history, so a conflict here is a runtime defect rather than a caller error.
    private func apply(_ commit: TurnLedgerCommit) throws {
        for message in commit.appendedMessages {
            try appendMessage(message)
        }
        for turn in commit.upsertedTurns {
            turns[turn.identity.turnID] = turn
        }
        for intent in commit.upsertedToolIntents {
            intents[ToolKey(turnID: intent.turnID, toolCallID: intent.toolCallID)] = intent
        }
        for result in commit.upsertedToolResults {
            results[ToolKey(turnID: result.turnID, toolCallID: result.toolCallID)] = result
        }
        guard let timelineID = commit.pointerTimelineID else { return }
        if let activeTurnID = commit.activeTurnID {
            activeTurns[timelineID] = activeTurnID
        } else {
            activeTurns.removeValue(forKey: timelineID)
        }
        if let quarantinedTurnID = commit.quarantinedTurnID {
            quarantinedTurns[timelineID] = quarantinedTurnID
        } else {
            quarantinedTurns.removeValue(forKey: timelineID)
        }
    }

    // MARK: Internal transition helpers

    private func mutableTurn(_ turnID: UUID) throws -> TurnRecord {
        guard let turn = turns[turnID] else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        return turn
    }
}
