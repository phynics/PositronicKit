import Foundation
import PKContracts
import PKUtilities

/// An actor-backed reference implementation of ``ThreadRuntimeRepository``.
///
/// The actor gives tests and local hosts one serialization boundary with the same transition
/// rules that a database-backed adapter must preserve. It is intentionally ephemeral; production
/// adapters should implement the protocol against a durable transaction.
public actor InMemoryThreadRuntimeRepository: ThreadRuntimeRepository, WorkspaceBindingRepository {
    private struct ToolKey: Hashable {
        let turnID: UUID
        let toolCallID: String
    }

    private var threads: [UUID: Thread] = [:]
    private var messages: [UUID: [ThreadMessage]] = [:]
    private var turns: [UUID: TurnRecord] = [:]
    private var activeTurns: [UUID: UUID] = [:]
    private var recoveryRequiredTurns: [UUID: UUID] = [:]
    private var intents: [ToolKey: RuntimeToolIntent] = [:]
    private var results: [ToolKey: RuntimeToolResult] = [:]
    private var summaries: [UUID: [ThreadSummary]] = [:]
    private var workspaceBindingsByWorkspace: [UUID: WorkspaceBinding] = [:]
    private var workspaceIDsByThread: [UUID: Set<UUID>] = [:]
    private let staleAfter: TimeInterval
    private let durable: Bool

    public nonisolated var isDurable: Bool {
        durable
    }

    /// - Parameter staleAfter: Age after which an active Turn is lazily interrupted during
    ///   recovery. A non-positive value makes every active Turn eligible for recovery.
    public init(staleAfter: TimeInterval = 300, isDurable: Bool = false) {
        self.staleAfter = staleAfter
        durable = isDurable
    }

    // MARK: ThreadPersistenceProtocol

    public func saveThread(_ thread: Thread) async throws {
        threads[thread.id] = thread
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        threads[id]
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        threads.values
            .filter { includeArchived || !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func deleteThread(id: UUID) async throws {
        threads.removeValue(forKey: id)
        // Cascade: destroying the Thread destroys its history. Append-only means "immutable
        // while the Thread lives," not "retained forever" — once the Thread row is gone, its
        // messages and summary projections become unreachable, so this conformer removes them
        // here rather than leaving them as an orphaned, unbounded leak. See the cascade contract
        // documented on `ThreadRuntimeRepository`.
        messages.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
        for workspaceID in workspaceIDsByThread.removeValue(forKey: id) ?? [] {
            workspaceBindingsByWorkspace.removeValue(forKey: workspaceID)
        }
        if let activeTurnID = activeTurns.removeValue(forKey: id) {
            turns[activeTurnID]?.recoveryRequired = true
            turns[activeTurnID]?.recoveryMessage = "Thread deleted while Turn was active."
            recoveryRequiredTurns[id] = activeTurnID
        }
    }

    public func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let excluded = Set(excludedThreadIDs)
        let eligible = threads.values.filter { !$0.id.isExcluded(by: excluded) && $0.updatedAt < cutoff }
        guard !dryRun else { return eligible.count }
        for thread in eligible {
            try await deleteThread(id: thread.id)
        }
        return eligible.count
    }

    // MARK: ThreadMessageStoreProtocol

    public func saveMessage(_ message: ThreadMessage) async throws {
        try appendMessage(message)
    }

    /// Appends a message without an actor suspension. Admission uses this helper so the input
    /// message and Turn record become visible as one actor-isolated transition.
    private func appendMessage(_ message: ThreadMessage) throws {
        var history = messages[message.threadID, default: []]
        if let existing = history.first(where: { $0.id == message.id }) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let existingData = try encoder.encode(existing)
            let newData = try encoder.encode(message)
            guard existingData == newData else {
                throw ThreadRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
            }
            return
        }
        history.append(message)
        messages[message.threadID] = history
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
        messages[threadID, default: []]
    }

    public func deleteMessages(for threadID: UUID) async throws {
        throw ThreadRuntimeRepositoryError.historyDeletionForbidden(threadID: threadID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let count = messages.values.reduce(into: 0) { result, history in
            result += history.filter { $0.timestamp < cutoff }.count
        }
        guard !dryRun else { return count }
        // A preview is useful to an administrator, but the runtime repository never deletes
        // history as part of an ordinary transition.
        guard let threadID = messages.keys.first else { return 0 }
        throw ThreadRuntimeRepositoryError.historyDeletionForbidden(threadID: threadID)
    }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        messages[threadID, default: []]
            .filter { $0.role == "assistant" }
            .compactMap { message in
                guard let data = message.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }

    // MARK: Admission

    public func admitTurn(
        threadID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: ThreadMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        guard threads[threadID] != nil else {
            throw ThreadRuntimeRepositoryError.threadNotFound(threadID)
        }

        if let inputMessage, inputMessage.threadID != threadID {
            throw ThreadRuntimeRepositoryError.inputMessageThreadMismatch(
                messageID: inputMessage.id,
                expectedThreadID: threadID,
                actualThreadID: inputMessage.threadID
            )
        }

        let callerIntent = TurnCallerIntent(requestID: requestID, fingerprint: callerIntentFingerprint)
        let matching = turns.values
            .filter { $0.threadID == threadID && $0.callerIntent.requestID == requestID }
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
            if matching.callerIntent.fingerprint == callerIntentFingerprint,
               matching.recoveryRequired
            {
                // A force-interrupted attempt remains visible as a replay of the original
                // request while recovery is pending. Distinct requests are rejected below until
                // the host explicitly clears the recovery marker.
                return TurnAdmission(disposition: .replayed, turn: matching)
            }
            // A failed/cancelled/interrupted attempt may be retried with the same request ID,
            // whether the retry repeats the exact input or supplies changed tool outputs. The
            // retry is a new durable Turn linked to the failed attempt; completed Turns and
            // active attempts remain strict idempotency conflicts.
            guard matching.isTerminal,
                  matching.recoveryRequired == false,
                  !isCompleted(matching.outcome)
            else {
                throw ThreadRuntimeRepositoryError.idempotencyConflict(requestID: requestID)
            }
            retryRelation = TurnRetryRelation(
                retriedTurnID: matching.identity.turnID,
                attempt: (matching.retryRelation?.attempt ?? 0) + 1
            )
        }

        if let recoveryTurnID = recoveryRequiredTurns[threadID] {
            throw ThreadRuntimeRepositoryError.recoveryRequired(threadID: threadID, turnID: recoveryTurnID)
        }
        if let activeTurnID = activeTurns[threadID], let active = turns[activeTurnID] {
            if active.recoveryRequired {
                throw ThreadRuntimeRepositoryError.recoveryRequired(threadID: threadID, turnID: activeTurnID)
            }
            throw ThreadRuntimeRepositoryError.threadBusy(threadID: threadID, activeTurnID: activeTurnID)
        }

        let identity = TurnIdentity(turnID: turnID, requestID: requestID, modelRoundIndex: 0)
        let record = TurnRecord(
            identity: identity,
            threadID: threadID,
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
            if let existing = messages[threadID]?.first(where: { $0.id == inputMessage.id }) {
                guard messagesEquivalentIgnoringTimestamp(existing, inputMessage) else {
                    throw ThreadRuntimeRepositoryError.appendOnlyViolation(messageID: inputMessage.id)
                }
            } else {
                try appendMessage(inputMessage)
            }
        }
        turns[turnID] = record
        activeTurns[threadID] = turnID
        return TurnAdmission(disposition: .admitted, turn: record)
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        turns[id]
    }

    public func fetchActiveTurn(for threadID: UUID) async throws -> TurnRecord? {
        guard let id = activeTurns[threadID] else { return nil }
        return turns[id]
    }

    public func admitRetry(
        threadID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: ThreadMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) async throws -> TurnAdmission {
        guard let previous = turns[previousTurnID], previous.threadID == threadID else {
            throw ThreadRuntimeRepositoryError.turnNotFound(previousTurnID)
        }
        var admission = try await admitTurn(
            threadID: threadID,
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
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
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
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        let unresolved = intents.values
            .filter { $0.turnID == turnID && $0.modelRoundIndex < modelRoundIndex }
            .first { results[ToolKey(turnID: $0.turnID, toolCallID: $0.toolCallID)] == nil }
        if let unresolved {
            throw ThreadRuntimeRepositoryError.toolIntentRequired(turnID: turnID, toolCallID: unresolved.toolCallID)
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
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: turnID, lifecycle: turn.lifecycle)
        }
        turn.lifecycle = .running
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "provider-request-durable", message: "(modelRoundIndex)", createdAt: now))
        if let correlation { turn.correlations.append(correlation) }
        turns[turnID] = turn
    }

    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        var turn = try mutableTurn(intent.turnID)
        guard turn.threadID == intent.threadID, !turn.isTerminal else {
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: intent.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: intent.turnID, toolCallID: intent.toolCallID)
        if intents[key] != nil {
            throw ThreadRuntimeRepositoryError.duplicateToolIntent(turnID: intent.turnID, toolCallID: intent.toolCallID)
        }
        intents[key] = intent
        turn.lifecycle = .awaitingTool
        turn.updatedAt = intent.createdAt
        turn.notices.append(TurnNotice(kind: "tool-intent-durable", message: intent.toolCallID, createdAt: intent.createdAt))
        turns[intent.turnID] = turn
    }

    public func recordToolResult(_ result: RuntimeToolResult) async throws {
        var turn = try mutableTurn(result.turnID)
        guard turn.threadID == result.threadID, !turn.isTerminal else {
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: result.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: result.turnID, toolCallID: result.toolCallID)
        guard intents[key] != nil else {
            throw ThreadRuntimeRepositoryError.toolIntentRequired(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        guard results[key] == nil else {
            throw ThreadRuntimeRepositoryError.duplicateToolResult(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        results[key] = result
        turn.lifecycle = .running
        turn.updatedAt = result.createdAt
        turn.notices.append(TurnNotice(kind: "tool-result-durable", message: result.toolCallID, createdAt: result.createdAt))
        turns[result.turnID] = turn
    }

    public func recordToolResult(_ result: RuntimeToolResult, message: ThreadMessage) async throws {
        var turn = try mutableTurn(result.turnID)
        guard turn.threadID == result.threadID,
              message.threadID == result.threadID,
              !turn.isTerminal
        else {
            throw ThreadRuntimeRepositoryError.invalidTransition(turnID: result.turnID, lifecycle: turn.lifecycle)
        }
        let key = ToolKey(turnID: result.turnID, toolCallID: result.toolCallID)
        guard intents[key] != nil else {
            throw ThreadRuntimeRepositoryError.toolIntentRequired(turnID: result.turnID, toolCallID: result.toolCallID)
        }
        guard results[key] == nil else {
            throw ThreadRuntimeRepositoryError.duplicateToolResult(turnID: result.turnID, toolCallID: result.toolCallID)
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
        finalMessage: ThreadMessage?,
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
            throw ThreadRuntimeRepositoryError.toolIntentRequired(turnID: turnID, toolCallID: pending.toolCallID)
        }
        if let finalMessage {
            guard finalMessage.threadID == turn.threadID else {
                throw ThreadRuntimeRepositoryError.finalMessageThreadMismatch(
                    messageID: finalMessage.id,
                    expectedThreadID: turn.threadID,
                    actualThreadID: finalMessage.threadID
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
        activeTurns.removeValue(forKey: turn.threadID)
        turns[turnID] = turn
        return turn
    }

    public func failTurn(turnID: UUID, message: String, now: Date) async throws -> TurnRecord {
        try await completeTurn(turnID: turnID, outcome: .failed(message: message), finalMessage: nil, terminalHandle: nil, now: now)
    }

    public func cancelTurn(turnID: UUID, reason: String?, now: Date) async throws -> TurnRecord {
        try await completeTurn(turnID: turnID, outcome: .cancelled(reason: reason), finalMessage: nil, terminalHandle: nil, now: now)
    }

    public func interruptTurn(turnID: UUID, reason: String, force: Bool, now: Date) async throws -> TurnRecord {
        var turn = try mutableTurn(turnID)
        guard !turn.isTerminal || force else { return turn }
        turn.outcome = .interrupted(reason: reason)
        turn.lifecycle = .interrupted
        turn.recoveryRequired = force
        turn.recoveryMessage = force ? reason : nil
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: force ? "turn-force-interrupted" : "turn-interrupted", message: reason, createdAt: now))
        activeTurns.removeValue(forKey: turn.threadID)
        if force {
            recoveryRequiredTurns[turn.threadID] = turnID
        }
        turns[turnID] = turn
        return turn
    }

    public func recover(threadID: UUID, now: Date) async throws -> TurnRecoveryResult {
        if let recoveryID = recoveryRequiredTurns[threadID], let recovery = turns[recoveryID] {
            return .recoveryRequired(recovery)
        }
        guard let activeID = activeTurns[threadID], let active = turns[activeID] else {
            return .noActiveTurn
        }
        guard now.timeIntervalSince(active.updatedAt) >= staleAfter else {
            return .active(active)
        }
        let interrupted = try await interruptTurn(
            turnID: activeID,
            reason: "Turn exceeded the stale recovery threshold.",
            force: true,
            now: now
        )
        return .recoveryRequired(interrupted)
    }

    public func forceClear(
        threadID: UUID,
        confirmation: ForceClearConfirmation,
        now: Date
    ) async throws -> TurnRecord? {
        guard confirmation.phrase == ForceClearConfirmation.requiredPhrase else {
            throw ThreadRuntimeRepositoryError.confirmationRequired
        }
        let activeID = activeTurns.removeValue(forKey: threadID) ?? recoveryRequiredTurns[threadID]
        guard let activeID, var turn = turns[activeID] else {
            return nil
        }
        turn.recoveryRequired = true
        turn.recoveryMessage = "Active pointer force-cleared by an administrator."
        turn.updatedAt = now
        turn.notices.append(TurnNotice(kind: "turn-force-cleared", createdAt: now))
        recoveryRequiredTurns[threadID] = activeID
        turns[activeID] = turn
        return turn
    }

    // MARK: Summary projections

    public func saveSummary(_ summary: ThreadSummary) async throws {
        guard threads[summary.threadID] != nil else {
            throw ThreadRuntimeRepositoryError.threadNotFound(summary.threadID)
        }
        let durableIDs = Set(messages[summary.threadID, default: []].map(\.id))
        guard let missing = summary.sourceMessageIDs.first(where: { !durableIDs.contains($0) }) else {
            var threadSummaries = summaries[summary.threadID, default: []]
            if let index = threadSummaries.firstIndex(where: { $0.id == summary.id }) {
                threadSummaries[index] = summary
            } else {
                threadSummaries.append(summary)
            }
            summaries[summary.threadID] = threadSummaries
            return
        }
        throw ThreadRuntimeRepositoryError.summarySourceMissing(messageID: missing)
    }

    public func fetchSummaries(for threadID: UUID) async throws -> [ThreadSummary] {
        summaries[threadID, default: []]
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for threadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        if let existing = workspaceBindingsByWorkspace[workspaceID] {
            guard existing.threadID == threadID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    threadID: existing.threadID
                )
            }
            return existing
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            threadID: threadID,
            createdAt: now,
            updatedAt: now
        )
        workspaceBindingsByWorkspace[workspaceID] = binding
        workspaceIDsByThread[threadID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from threadID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = workspaceBindingsByWorkspace[workspaceID], existing.threadID == threadID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                threadID: threadID
            )
        }
        workspaceBindingsByWorkspace.removeValue(forKey: workspaceID)
        workspaceIDsByThread[threadID]?.remove(workspaceID)
        if workspaceIDsByThread[threadID]?.isEmpty == true {
            workspaceIDsByThread.removeValue(forKey: threadID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceThreadID: UUID,
        to destinationThreadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = workspaceBindingsByWorkspace[workspaceID], existing.threadID == sourceThreadID else {
            throw WorkspaceBindingRepositoryError.transferSourceMismatch(
                workspaceID: workspaceID,
                threadID: sourceThreadID
            )
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            threadID: destinationThreadID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        workspaceBindingsByWorkspace[workspaceID] = binding
        workspaceIDsByThread[sourceThreadID]?.remove(workspaceID)
        if workspaceIDsByThread[sourceThreadID]?.isEmpty == true {
            workspaceIDsByThread.removeValue(forKey: sourceThreadID)
        }
        workspaceIDsByThread[destinationThreadID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for threadID: UUID) async throws -> [WorkspaceBinding] {
        (workspaceIDsByThread[threadID] ?? [])
            .compactMap { workspaceBindingsByWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func threadID(for workspaceID: UUID) async throws -> UUID? {
        workspaceBindingsByWorkspace[workspaceID]?.threadID
    }

    // MARK: Internal transition helpers

    private func mutableTurn(_ turnID: UUID) throws -> TurnRecord {
        guard let turn = turns[turnID] else {
            throw ThreadRuntimeRepositoryError.turnNotFound(turnID)
        }
        return turn
    }

    private func firstUnresolvedToolIntent(turnID: UUID) async throws -> RuntimeToolIntent? {
        intents.values
            .filter { $0.turnID == turnID }
            .sorted { $0.createdAt < $1.createdAt }
            .first { results[ToolKey(turnID: turnID, toolCallID: $0.toolCallID)] == nil }
    }

    private func validateAppend(_ message: ThreadMessage, into history: inout [ThreadMessage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let existing = history.first(where: { $0.id == message.id }) {
            let existingData = try encoder.encode(existing)
            let newData = try encoder.encode(message)
            guard existingData == newData else {
                throw ThreadRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
            }
            return
        }
        _ = try encoder.encode(message)
        history.append(message)
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

    private func messagesEquivalentIgnoringTimestamp(_ lhs: ThreadMessage, _ rhs: ThreadMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.threadID == rhs.threadID
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
