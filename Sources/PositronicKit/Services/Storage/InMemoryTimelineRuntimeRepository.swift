import Foundation
import PKContracts
import PKUtilities

/// An actor-backed reference implementation of ``TimelineRuntimeRepository``.
///
/// The actor gives tests and local hosts one serialization boundary with the same transition
/// rules that a database-backed adapter must preserve. It is intentionally ephemeral; production
/// adapters should implement the protocol against a durable transaction.
public actor InMemoryTimelineRuntimeRepository: TimelineRuntimeRepository, WorkspaceBindingRepository, TimelineSummaryStore {
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
    private var summaries: [UUID: [TimelineSummary]] = [:]
    private var workspaceBindingsByWorkspace: [UUID: WorkspaceBinding] = [:]
    private var workspaceIDsByTimeline: [UUID: Set<UUID>] = [:]
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
        // messages and summary projections become unreachable, so this conformer removes them
        // here rather than leaving them as an orphaned, unbounded leak. See the cascade contract
        // documented on `TimelineRuntimeRepository`.
        messages.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
        for workspaceID in workspaceIDsByTimeline.removeValue(forKey: id) ?? [] {
            workspaceBindingsByWorkspace.removeValue(forKey: workspaceID)
        }
        if let activeTurnID = activeTurns.removeValue(forKey: id) {
            turns[activeTurnID]?.quarantine = TurnQuarantine(
                reason: "Timeline deleted while Turn was active."
            )
            quarantinedTurns[id] = activeTurnID
        }
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let excluded = Set(excludedTimelineIDs)
        let eligible = timelines.values.filter { !$0.id.isExcluded(by: excluded) && $0.updatedAt < cutoff }
        guard !dryRun else { return eligible.count }
        for timeline in eligible {
            try await deleteTimeline(id: timeline.id)
        }
        return eligible.count
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
        messages[timelineID, default: []]
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    public func deleteMessages(for timelineID: UUID) async throws {
        throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: timelineID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let count = messages.values.reduce(into: 0) { result, history in
            result += history.filter { $0.timestamp < cutoff }.count
        }
        guard !dryRun else { return count }
        // A preview is useful to an administrator, but the runtime repository never deletes
        // history as part of an ordinary transition.
        guard let timelineID = messages.keys.first else { return 0 }
        throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: timelineID)
    }

    public func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        messages[timelineID, default: []]
            .filter { $0.role == "assistant" }
            .compactMap { message in
                guard let data = message.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
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
        guard timelines[timelineID] != nil else {
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
        let matching = turns.values
            .filter { $0.timelineID == timelineID && $0.callerIntent.requestID == requestID }
            .max { $0.createdAt < $1.createdAt }
        var retryRelation: TurnRetryRelation?
        if let matching {
            if matching.callerIntent.fingerprint == callerIntentFingerprint, !matching.isTerminal {
                return TurnAdmission(disposition: .joined, turn: matching)
            }
            if matching.callerIntent.fingerprint == callerIntentFingerprint,
               isCompleted(matching.outcome)
            {
                return TurnAdmission(disposition: .replayed, turn: matching)
            }
            if matching.isQuarantined {
                // A quarantined Timeline rejects admission until an operator releases it; the
                // original request ID may not be replayed while the side effect is unreconciled.
                throw TimelineRuntimeRepositoryError.timelineQuarantined(
                    timelineID: timelineID,
                    turnID: matching.identity.turnID
                )
            }
            // A failed/cancelled/interrupted attempt may be retried with the same request ID,
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

        if let quarantineTurnID = quarantinedTurns[timelineID] {
            throw TimelineRuntimeRepositoryError.timelineQuarantined(timelineID: timelineID, turnID: quarantineTurnID)
        }
        if let activeTurnID = activeTurns[timelineID] {
            throw TimelineRuntimeRepositoryError.timelineBusy(timelineID: timelineID, activeTurnID: activeTurnID)
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
            createdAt: now,
            updatedAt: now
        )
        if let inputMessage {
            if let existing = messages[timelineID]?.first(where: { $0.id == inputMessage.id }) {
                guard messagesEquivalentIgnoringTimestamp(existing, inputMessage) else {
                    throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: inputMessage.id)
                }
            } else {
                try appendMessage(inputMessage)
            }
        }
        turns[turnID] = record
        activeTurns[timelineID] = turnID
        return TurnAdmission(disposition: .admitted, turn: record)
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        turns[id]
    }

    public func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        guard let id = activeTurns[timelineID] else { return nil }
        return turns[id]
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
        guard let previous = turns[previousTurnID], previous.timelineID == timelineID else {
            throw TimelineRuntimeRepositoryError.turnNotFound(previousTurnID)
        }
        var admission = try await admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
        guard admission.disposition == .admitted else { return admission }
        var record = admission.turn
        record.retryRelation = TurnRetryRelation(retriedTurnID: previousTurnID, attempt: attempt)
        turns[turnID] = record
        admission = TurnAdmission(disposition: .admitted, turn: record)
        return admission
    }

    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        var turn = try mutableTurn(turnID)
        turn.notices.append(notice)
        turn.updatedAt = notice.createdAt
        turns[turnID] = turn
    }

    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        turn.correlations.append(correlation)
        turn.updatedAt = now
        turns[turnID] = turn
    }

    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try mutableTurn(turnID).notices
    }

    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try mutableTurn(turnID).correlations
    }

    // MARK: Ordering barriers

    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        let unresolved = intents.values
            .filter { $0.turnID == turnID && $0.modelRoundIndex < modelRoundIndex }
            .first { results[ToolKey(turnID: $0.turnID, toolCallID: $0.toolCallID)] == nil }
        if let unresolved {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(turnID: turnID, toolCallID: unresolved.toolCallID)
        }
        turn.lifecycle = .running
        turn.currentModelRoundIndex = modelRoundIndex
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "model-round-started", message: "(modelRoundIndex)", createdAt: now))
        turns[turnID] = turn
    }

    public func recordProviderRequest(
        turnID: UUID,
        modelRoundIndex _: Int,
        correlation: TurnCorrelation?,
        now: Date
    ) async throws {
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        turn.lifecycle = .running
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "provider-request-durable", message: "(modelRoundIndex)", createdAt: now))
        if let correlation { turn.correlations.append(correlation) }
        turns[turnID] = turn
    }

    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        var turn = try mutableTurn(intent.turnID)
        guard turn.timelineID == intent.timelineID, !turn.isTerminal else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: intent.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: intent.turnID, toolCallID: intent.toolCallID)
        if intents[key] != nil {
            throw TimelineRuntimeRepositoryError.duplicateToolIntent(turnID: intent.turnID, toolCallID: intent.toolCallID)
        }
        intents[key] = intent
        turn.lifecycle = .awaitingTool
        turn.updatedAt = intent.createdAt
        turn.notices.append(TurnNotice(kind: "tool-intent-durable", message: intent.toolCallID, createdAt: intent.createdAt))
        turns[intent.turnID] = turn
    }

    public func recordToolResult(_ result: RuntimeToolResult) async throws {
        var turn = try mutableTurn(result.turnID)
        guard turn.timelineID == result.timelineID, !turn.isTerminal else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: result.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: result.turnID, toolCallID: result.toolCallID)
        guard intents[key] != nil else {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        guard results[key] == nil else {
            throw TimelineRuntimeRepositoryError.duplicateToolResult(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        results[key] = result
        turn.lifecycle = .running
        turn.updatedAt = result.createdAt
        turn.notices.append(TurnNotice(kind: "tool-result-durable", message: result.toolCallID, createdAt: result.createdAt))
        turns[result.turnID] = turn
    }

    public func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
        var turn = try mutableTurn(result.turnID)
        guard turn.timelineID == result.timelineID,
              message.timelineID == result.timelineID,
              !turn.isTerminal
        else {
            throw TimelineRuntimeRepositoryError.invalidTransition(turnID: result.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: result.turnID, toolCallID: result.toolCallID)
        guard intents[key] != nil else {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        guard results[key] == nil else {
            throw TimelineRuntimeRepositoryError.duplicateToolResult(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        // Validate the append before mutating either side of the transition. Once this actor
        // returns, the message and result are visible together to the next model round.
        try appendMessage(message)
        results[key] = result
        turn.lifecycle = .running
        turn.updatedAt = result.createdAt
        turn.notices.append(TurnNotice(kind: "tool-result-durable", message: result.toolCallID, createdAt: result.createdAt))
        turns[result.turnID] = turn
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
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal else {
            return turn
        }
        if case .completed = outcome,
           let pending = try await firstUnresolvedToolIntent(turnID: turnID)
        {
            throw TimelineRuntimeRepositoryError.toolIntentRequired(turnID: turnID, toolCallID: pending.toolCallID)
        }
        if let finalMessage {
            guard finalMessage.timelineID == turn.timelineID else {
                throw TimelineRuntimeRepositoryError.finalMessageTimelineMismatch(
                    messageID: finalMessage.id,
                    expectedTimelineID: turn.timelineID,
                    actualTimelineID: finalMessage.timelineID
                )
            }
            try appendMessage(finalMessage)
        }
        turn.outcome = outcome
        turn.lifecycle = lifecycle(for: outcome)
        turn.terminalHandle = terminalHandle
        turn.terminalMessageID = finalMessage?.id
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "turn-terminal", message: terminalMessage(for: outcome), createdAt: now))
        activeTurns.removeValue(forKey: turn.timelineID)
        turns[turnID] = turn
        return turn
    }

    public func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult {
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal else {
            // First-writer-wins: the Turn's owner already committed a terminal outcome, so the
            // interruption changes nothing and reports the durable record.
            return .alreadyTerminal(turn)
        }
        turn.outcome = .interrupted(reason: reason)
        turn.lifecycle = .interrupted
        turn.updatedAt = now
        switch disposition {
        case .retryable:
            turn.quarantine = nil
            // Only clear this Turn's own quarantine marker; a marker for a different Turn (for
            // example one quarantined by `deleteTimeline`) stays until the operator releases it.
            if quarantinedTurns[turn.timelineID] == turnID {
                quarantinedTurns.removeValue(forKey: turn.timelineID)
            }
            turn.notices.append(TurnNotice(kind: "turn-interrupted", message: reason, createdAt: now))
        case let .quarantined(message):
            turn.quarantine = TurnQuarantine(reason: message, createdAt: now)
            quarantinedTurns[turn.timelineID] = turnID
            turn.notices.append(TurnNotice(kind: "turn-quarantined", message: message, createdAt: now))
        }
        activeTurns.removeValue(forKey: turn.timelineID)
        turns[turnID] = turn
        return .interrupted(turn)
    }

    public func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord {
        guard confirmation.phrase == QuarantineReleaseConfirmation.requiredPhrase else {
            throw TimelineRuntimeRepositoryError.confirmationRequired
        }
        var turn = try mutableTurn(turnID)
        guard turn.timelineID == timelineID, turn.isQuarantined else {
            throw TimelineRuntimeRepositoryError.quarantineNotFound(timelineID: timelineID, turnID: turnID)
        }
        turn.quarantine = nil
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "turn-quarantine-released", createdAt: now))
        turns[turnID] = turn
        if quarantinedTurns[timelineID] == turnID {
            quarantinedTurns.removeValue(forKey: timelineID)
        }
        return turn
    }

    // MARK: Summary projections

    public func saveSummary(_ summary: TimelineSummary) async throws {
        guard timelines[summary.timelineID] != nil else {
            throw TimelineRuntimeRepositoryError.timelineNotFound(summary.timelineID)
        }
        let durableIDs = Set(messages[summary.timelineID, default: []].map(\.id))
        guard let missing = summary.sourceMessageIDs.first(where: { !durableIDs.contains($0) }) else {
            var timelineSummaries = summaries[summary.timelineID, default: []]
            if let index = timelineSummaries.firstIndex(where: { $0.id == summary.id }) {
                timelineSummaries[index] = summary
            } else {
                timelineSummaries.append(summary)
            }
            summaries[summary.timelineID] = timelineSummaries
            return
        }
        throw TimelineRuntimeRepositoryError.summarySourceMissing(messageID: missing)
    }

    public func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] {
        summaries[timelineID, default: []]
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        if let existing = workspaceBindingsByWorkspace[workspaceID] {
            guard existing.timelineID == timelineID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    timelineID: existing.timelineID
                )
            }
            return existing
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            timelineID: timelineID,
            createdAt: now,
            updatedAt: now
        )
        workspaceBindingsByWorkspace[workspaceID] = binding
        workspaceIDsByTimeline[timelineID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = workspaceBindingsByWorkspace[workspaceID], existing.timelineID == timelineID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                timelineID: timelineID
            )
        }
        workspaceBindingsByWorkspace.removeValue(forKey: workspaceID)
        workspaceIDsByTimeline[timelineID]?.remove(workspaceID)
        if workspaceIDsByTimeline[timelineID]?.isEmpty == true {
            workspaceIDsByTimeline.removeValue(forKey: timelineID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = workspaceBindingsByWorkspace[workspaceID], existing.timelineID == sourceTimelineID else {
            throw WorkspaceBindingRepositoryError.transferSourceMismatch(
                workspaceID: workspaceID,
                timelineID: sourceTimelineID
            )
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            timelineID: destinationTimelineID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        workspaceBindingsByWorkspace[workspaceID] = binding
        workspaceIDsByTimeline[sourceTimelineID]?.remove(workspaceID)
        if workspaceIDsByTimeline[sourceTimelineID]?.isEmpty == true {
            workspaceIDsByTimeline.removeValue(forKey: sourceTimelineID)
        }
        workspaceIDsByTimeline[destinationTimelineID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        (workspaceIDsByTimeline[timelineID] ?? [])
            .compactMap { workspaceBindingsByWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        workspaceBindingsByWorkspace[workspaceID]?.timelineID
    }

    // MARK: Internal transition helpers

    private func mutableTurn(_ turnID: UUID) throws -> TurnRecord {
        guard let turn = turns[turnID] else {
            throw TimelineRuntimeRepositoryError.turnNotFound(turnID)
        }
        return turn
    }

    private func firstUnresolvedToolIntent(turnID: UUID) async throws -> RuntimeToolIntent? {
        intents.values
            .filter { $0.turnID == turnID }
            .sorted { $0.createdAt < $1.createdAt }
            .first { results[ToolKey(turnID: turnID, toolCallID: $0.toolCallID)] == nil }
    }

    private func lifecycle(for outcome: TurnOutcome) -> TurnLifecycle {
        switch outcome {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        }
    }

    private func isCompleted(_ outcome: TurnOutcome?) -> Bool {
        if case .completed? = outcome { return true }
        return false
    }

    private func messagesEquivalentIgnoringTimestamp(_ lhs: TimelineMessage, _ rhs: TimelineMessage) -> Bool {
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

    private func terminalMessage(for outcome: TurnOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case let .failed(message): return "failed: \(message)"
        case let .cancelled(reason): return "cancelled\(reason.map { ": \($0)" } ?? "")"
        case let .interrupted(reason): return "interrupted: \(reason)"
        }
    }
}

private extension UUID {
    func isExcluded(by excluded: Set<UUID>) -> Bool {
        excluded.contains(self)
    }
}
