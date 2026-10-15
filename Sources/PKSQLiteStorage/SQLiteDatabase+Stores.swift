import Foundation
import PKContracts
import PositronicKit

// MARK: - Timeline persistence

extension SQLiteDatabase {
    func saveTimeline(_ timeline: TimelineRecord) async throws {
        try withTransaction { try upsertTimeline(timeline) }
    }

    func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        try loadTimeline(id: id)
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        let sql = includeArchived
            ? "SELECT body FROM timelines ORDER BY created_at ASC, id ASC"
            : "SELECT body FROM timelines WHERE is_archived = 0 ORDER BY created_at ASC, id ASC"
        let statement = try prepare(sql)
        defer { finalize(statement) }
        var timelines: [TimelineRecord] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            timelines.append(try pkDecodeJSON(TimelineRecord.self, from: body))
        }
        return timelines
    }

    func deleteTimeline(id: UUID) async throws {
        try withTransaction { try deleteTimelineSync(id) }
    }

    func deleteEphemeralTimeline(id: UUID) async throws {
        guard let timeline = try loadTimeline(id: id) else { return }
        guard timeline.isEphemeral else {
            throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: id)
        }
        try withTransaction { try deleteTimelineSync(id) }
    }

    func purgeEphemeralTimelines() async throws {
        let statement = try prepare("SELECT id FROM timelines WHERE is_ephemeral = 1")
        defer { finalize(statement) }
        var ids: [String] = []
        while try step(statement) {
            if let id = text(statement, 0) { ids.append(id) }
        }
        guard !ids.isEmpty else { return }
        try withTransaction {
            for id in ids {
                guard let uuid = UUID(uuidString: id) else { continue }
                try deleteTimelineSync(uuid)
            }
        }
    }
}

// MARK: - Message store

extension SQLiteDatabase {
    func saveMessage(_ message: TimelineMessage) async throws {
        try withTransaction { try insertMessage(message) }
    }

    func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        try loadMessages(timelineID: timelineID)
    }
}

// MARK: - Turn runtime repository

extension SQLiteDatabase {
    func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        try withTransaction {
            let decision = try TurnLedger.decideAdmission(
                snapshot: try ledgerSnapshot(timelineID: timelineID),
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
    }

    func admitRetry(
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
        try withTransaction {
            let decision = try TurnLedger.decideAdmitRetry(
                snapshot: try ledgerSnapshot(timelineID: timelineID),
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
    }

    func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try loadTurn(id: id)
    }

    func recordTurnMessage(_ message: TimelineMessage, turnID: UUID) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideRecordTurnMessage(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                message: message
            )
            try apply(decision.commit)
        }
    }

    func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        guard let active = try loadPointer(timelineID: timelineID)?.activeTurnID else { return nil }
        return try loadTurn(id: active)
    }

    func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideAppendNotice(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                notice: notice
            )
            try apply(decision.commit)
        }
    }

    func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideAppendCorrelation(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                correlation: correlation,
                now: now
            )
            try apply(decision.commit)
        }
    }

    func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try requireTurn(id: turnID).notices
    }

    func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try requireTurn(id: turnID).correlations
    }

    func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideBeginModelRound(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                modelRoundIndex: modelRoundIndex,
                now: now
            )
            try apply(decision.commit)
        }
    }

    func recordProviderRequest(
        turnID: UUID,
        modelRoundIndex _: Int,
        correlation: TurnCorrelation?,
        now: Date
    ) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideRecordProviderRequest(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                correlation: correlation,
                now: now
            )
            try apply(decision.commit)
        }
    }

    func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideRecordToolIntent(
                snapshot: try ledgerSnapshot(turnID: intent.turnID),
                intent: intent
            )
            try apply(decision.commit)
        }
    }

    func recordToolResult(_ result: RuntimeToolResult) async throws {
        try await commitToolResult(result, message: nil)
    }

    func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
        try await commitToolResult(result, message: message)
    }

    func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] {
        try loadToolIntents(turnID: turnID)
    }

    func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] {
        try loadToolResults(turnID: turnID)
    }

    func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord {
        try withTransaction {
            let decision = try TurnLedger.decideCompleteTurn(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                outcome: outcome,
                finalMessage: finalMessage,
                terminalHandle: terminalHandle,
                now: now
            )
            try apply(decision.commit)
            return decision.result
        }
    }

    func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult {
        try withTransaction {
            let decision = try TurnLedger.decideInterruptTurn(
                snapshot: try ledgerSnapshot(turnID: turnID),
                turnID: turnID,
                reason: reason,
                disposition: disposition,
                now: now
            )
            try apply(decision.commit)
            return decision.result
        }
    }

    func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord {
        try withTransaction {
            let decision = try TurnLedger.decideReleaseQuarantine(
                snapshot: try ledgerSnapshot(turnID: turnID),
                timelineID: timelineID,
                turnID: turnID,
                confirmation: confirmation,
                now: now
            )
            try apply(decision.commit)
            return decision.result
        }
    }

    private func commitToolResult(_ result: RuntimeToolResult, message: TimelineMessage?) async throws {
        try withTransaction {
            let decision = try TurnLedger.decideRecordToolResult(
                snapshot: try ledgerSnapshot(turnID: result.turnID),
                result: result,
                message: message
            )
            try apply(decision.commit)
        }
    }
}

// MARK: - Workspace binding repository

extension SQLiteDatabase {
    func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding {
        try withTransaction {
            if let existing = try loadBinding(workspaceID: workspaceID) {
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
            try upsertBinding(binding)
            return binding
        }
    }

    func release(workspaceID: UUID, from timelineID: UUID, now _: Date) async throws {
        try withTransaction {
            guard let existing = try loadBinding(workspaceID: workspaceID),
                  existing.timelineID == timelineID
            else {
                throw WorkspaceBindingRepositoryError.bindingNotFound(
                    workspaceID: workspaceID,
                    timelineID: timelineID
                )
            }
            try deleteBinding(workspaceID: workspaceID)
        }
    }

    func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding {
        try withTransaction {
            guard let existing = try loadBinding(workspaceID: workspaceID),
                  existing.timelineID == sourceTimelineID
            else {
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
            try upsertBinding(binding)
            return binding
        }
    }

    func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        let statement = try prepare(
            "SELECT workspace_id, timeline_id, created_at, updated_at FROM workspace_bindings WHERE timeline_id = ? ORDER BY created_at ASC, workspace_id ASC"
        )
        defer { finalize(statement) }
        try bindText(statement, 1, timelineID.uuidString)
        var bindings: [WorkspaceBinding] = []
        while try step(statement) {
            if let binding = binding(from: statement) { bindings.append(binding) }
        }
        return bindings
    }

    func timelineID(for workspaceID: UUID) async throws -> UUID? {
        try loadBinding(workspaceID: workspaceID)?.timelineID
    }
}

// MARK: - Workspace store

extension SQLiteDatabase {
    func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        let body = try pkEncodeJSON(workspace)
        try withTransaction {
            try executeUpdate(
                "INSERT INTO workspaces (id, body) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body"
            ) {
                try bindText($0, 1, workspace.id.uuidString)
                try bindText($0, 2, body)
            }
        }
    }

    func fetchWorkspace(id: UUID, includeTools _: Bool) async throws -> WorkspaceReference? {
        guard let body = try queryText("SELECT body FROM workspaces WHERE id = ?", bind: {
            try bindText($0, 1, id.uuidString)
        }) else { return nil }
        return try pkDecodeJSON(WorkspaceReference.self, from: body)
    }

    func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        let statement = try prepare("SELECT body FROM workspaces ORDER BY id ASC")
        defer { finalize(statement) }
        var workspaces: [WorkspaceReference] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            workspaces.append(try pkDecodeJSON(WorkspaceReference.self, from: body))
        }
        return workspaces
    }

    func deleteWorkspace(id: UUID) async throws {
        try withTransaction {
            try executeUpdate("DELETE FROM workspaces WHERE id = ?") {
                try bindText($0, 1, id.uuidString)
            }
            try deleteBinding(workspaceID: id)
        }
    }
}

// MARK: - Agent store

extension SQLiteDatabase {
    func saveAgent(_ instance: Agent) async throws {
        let body = try pkEncodeJSON(instance)
        try withTransaction {
            try executeUpdate(
                "INSERT INTO agents (id, body) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body"
            ) {
                try bindText($0, 1, instance.id.uuidString)
                try bindText($0, 2, body)
            }
        }
    }

    func fetchAgent(id: UUID) async throws -> Agent? {
        guard let body = try queryText("SELECT body FROM agents WHERE id = ?", bind: {
            try bindText($0, 1, id.uuidString)
        }) else { return nil }
        return try pkDecodeJSON(Agent.self, from: body)
    }

    func fetchAllAgents() async throws -> [Agent] {
        let statement = try prepare("SELECT body FROM agents ORDER BY id ASC")
        defer { finalize(statement) }
        var agents: [Agent] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            agents.append(try pkDecodeJSON(Agent.self, from: body))
        }
        return agents
    }

    func deleteAgent(id: UUID) async throws {
        try withTransaction {
            try executeUpdate("DELETE FROM agents WHERE id = ?") {
                try bindText($0, 1, id.uuidString)
            }
        }
    }
}

// MARK: - Request origin store

extension SQLiteDatabase {
    func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        let body = try pkEncodeJSON(origin)
        try withTransaction {
            try executeUpdate(
                "INSERT INTO request_origins (id, body) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body"
            ) {
                try bindText($0, 1, origin.id.uuidString)
                try bindText($0, 2, body)
            }
        }
    }

    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        guard let body = try queryText("SELECT body FROM request_origins WHERE id = ?", bind: {
            try bindText($0, 1, id.uuidString)
        }) else { return nil }
        return try pkDecodeJSON(RequestOriginIdentity.self, from: body)
    }

    func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        let statement = try prepare("SELECT body FROM request_origins ORDER BY id ASC")
        defer { finalize(statement) }
        var origins: [RequestOriginIdentity] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            origins.append(try pkDecodeJSON(RequestOriginIdentity.self, from: body))
        }
        return origins
    }

    func deleteOrigin(id: UUID) async throws -> Bool {
        try withTransaction {
            let existed = try queryText("SELECT id FROM request_origins WHERE id = ?", bind: {
                try bindText($0, 1, id.uuidString)
            }) != nil
            guard existed else { return false }
            try executeUpdate("DELETE FROM request_origins WHERE id = ?") {
                try bindText($0, 1, id.uuidString)
            }
            return true
        }
    }
}

// MARK: - Private helpers

private extension SQLiteDatabase {
    // MARK: Ledger snapshots

    /// The Timeline-scoped ledger snapshot: every Turn and message for the Timeline plus its
    /// active and quarantine pointers.
    func ledgerSnapshot(timelineID: UUID) throws -> TurnLedgerSnapshot {
        let pointer = try loadPointer(timelineID: timelineID)
        return TurnLedgerSnapshot(
            timelineExists: try loadTimeline(id: timelineID) != nil,
            turns: try loadTurns(timelineID: timelineID),
            messages: try loadMessages(timelineID: timelineID),
            activeTurnID: pointer?.activeTurnID,
            quarantinedTurnID: pointer?.quarantinedTurnID
        )
    }

    /// The Turn-scoped ledger snapshot. The Turn must exist, so its Timeline is known before the
    /// load; the ledger compares any caller-supplied Timeline and reports a mismatch.
    func ledgerSnapshot(turnID: UUID) throws -> TurnLedgerSnapshot {
        let turn = try requireTurn(id: turnID)
        let pointer = try loadPointer(timelineID: turn.timelineID)
        return TurnLedgerSnapshot(
            timelineExists: try loadTimeline(id: turn.timelineID) != nil,
            turns: try loadTurns(timelineID: turn.timelineID),
            messages: try loadMessages(timelineID: turn.timelineID),
            activeTurnID: pointer?.activeTurnID,
            quarantinedTurnID: pointer?.quarantinedTurnID,
            toolIntents: try loadToolIntents(turnID: turnID),
            toolResults: try loadToolResults(turnID: turnID)
        )
    }

    /// Applies one ledger commit. The ledger has validated append-only history, so a conflict
    /// here is a runtime defect rather than a caller error.
    func apply(_ commit: TurnLedgerCommit) throws {
        for message in commit.appendedMessages {
            try insertMessage(message)
        }
        for turn in commit.upsertedTurns {
            try upsertTurn(turn)
        }
        for intent in commit.upsertedToolIntents {
            try upsertToolIntent(intent)
        }
        for result in commit.upsertedToolResults {
            try upsertToolResult(result)
        }
        guard let timelineID = commit.pointerTimelineID else { return }
        try upsertPointer(
            timelineID: timelineID,
            active: commit.activeTurnID,
            quarantined: commit.quarantinedTurnID
        )
    }

    // MARK: Timeline rows

    func upsertTimeline(_ timeline: TimelineRecord) throws {
        let body = try pkEncodeJSON(timeline)
        let principalID = timeline.attachedAgentID?.uuidString
        let principalKind = timeline.attachedAgentID == nil ? nil : "agent"
        try executeUpdate(
            """
            INSERT INTO timelines
                (id, body, is_archived, is_ephemeral, is_private, created_at, updated_at, principal_id, principal_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                body = excluded.body,
                is_archived = excluded.is_archived,
                is_ephemeral = excluded.is_ephemeral,
                is_private = excluded.is_private,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                principal_id = excluded.principal_id,
                principal_kind = excluded.principal_kind
            """
        ) {
            try bindText($0, 1, timeline.id.uuidString)
            try bindText($0, 2, body)
            try bindInt64($0, 3, timeline.isArchived ? 1 : 0)
            try bindInt64($0, 4, timeline.isEphemeral ? 1 : 0)
            try bindInt64($0, 5, timeline.isPrivate ? 1 : 0)
            try bindDouble($0, 6, timeline.createdAt.timeIntervalSince1970)
            try bindDouble($0, 7, timeline.updatedAt.timeIntervalSince1970)
            try bindText($0, 8, principalID)
            try bindText($0, 9, principalKind)
        }
    }

    func loadTimeline(id: UUID) throws -> TimelineRecord? {
        guard let body = try queryText("SELECT body FROM timelines WHERE id = ?", bind: {
            try bindText($0, 1, id.uuidString)
        }) else { return nil }
        return try pkDecodeJSON(TimelineRecord.self, from: body)
    }

    func deleteTimelineSync(_ id: UUID) throws {
        try executeUpdate("DELETE FROM messages WHERE timeline_id = ?") {
            try bindText($0, 1, id.uuidString)
        }
        try executeUpdate("DELETE FROM workspace_bindings WHERE timeline_id = ?") {
            try bindText($0, 1, id.uuidString)
        }
        // Match the InMemory contract: deleting a Timeline while a Turn is active marks that
        // Turn quarantined and leaves the Turn record as the audit trail.
        if let active = try loadPointer(timelineID: id)?.activeTurnID,
           var turn = try loadTurn(id: active)
        {
            turn.quarantine = TurnQuarantine(reason: "Timeline deleted while Turn was active.")
            try upsertTurn(turn)
            try upsertPointer(timelineID: id, active: nil, quarantined: active)
        }
        try executeUpdate("DELETE FROM timelines WHERE id = ?") {
            try bindText($0, 1, id.uuidString)
        }
    }

    // MARK: Message rows

    func insertMessage(_ message: TimelineMessage) throws {
        if let existingBody = try queryText(
            "SELECT body FROM messages WHERE timeline_id = ? AND id = ?",
            bind: {
                try bindText($0, 1, message.timelineID.uuidString)
                try bindText($0, 2, message.id.uuidString)
            }
        ) {
            let existing = try pkDecodeJSON(TimelineMessage.self, from: existingBody)
            guard try pkEncodeJSON(existing) == pkEncodeJSON(message) else {
                throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: message.id)
            }
            return
        }
        let body = try pkEncodeJSON(message)
        let principalID = message.agentID?.uuidString
        let principalKind = message.agentID == nil ? nil : "agent"
        try executeUpdate(
            """
            INSERT INTO messages
                (timeline_id, id, created_at, principal_id, principal_kind, body)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        ) {
            try bindText($0, 1, message.timelineID.uuidString)
            try bindText($0, 2, message.id.uuidString)
            try bindDouble($0, 3, message.timestamp.timeIntervalSince1970)
            try bindText($0, 4, principalID)
            try bindText($0, 5, principalKind)
            try bindText($0, 6, body)
        }
    }

    func loadMessages(timelineID: UUID) throws -> [TimelineMessage] {
        let statement = try prepare(
            "SELECT body FROM messages WHERE timeline_id = ? ORDER BY created_at ASC, seq ASC"
        )
        defer { finalize(statement) }
        try bindText(statement, 1, timelineID.uuidString)
        var messages: [TimelineMessage] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            messages.append(try pkDecodeJSON(TimelineMessage.self, from: body))
        }
        return messages
    }

    // MARK: Turn rows

    func upsertTurn(_ turn: TurnRecord) throws {
        let body = try pkEncodeJSON(turn)
        let principalID = turn.capturedAgentID?.uuidString
        let principalKind = turn.capturedAgentID == nil ? nil : "agent"
        try executeUpdate(
            """
            INSERT INTO turns
                (turn_id, timeline_id, request_id, fingerprint, created_at, is_terminal, is_quarantined, principal_id, principal_kind, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(turn_id) DO UPDATE SET
                timeline_id = excluded.timeline_id,
                request_id = excluded.request_id,
                fingerprint = excluded.fingerprint,
                created_at = excluded.created_at,
                is_terminal = excluded.is_terminal,
                is_quarantined = excluded.is_quarantined,
                principal_id = excluded.principal_id,
                principal_kind = excluded.principal_kind,
                body = excluded.body
            """
        ) {
            try bindText($0, 1, turn.identity.turnID.uuidString)
            try bindText($0, 2, turn.timelineID.uuidString)
            try bindText($0, 3, turn.callerIntent.requestID.uuidString)
            try bindText($0, 4, turn.callerIntent.fingerprint)
            try bindDouble($0, 5, turn.createdAt.timeIntervalSince1970)
            try bindInt64($0, 6, turn.isTerminal ? 1 : 0)
            try bindInt64($0, 7, turn.isQuarantined ? 1 : 0)
            try bindText($0, 8, principalID)
            try bindText($0, 9, principalKind)
            try bindText($0, 10, body)
        }
        if let members = turn.memberMessageIDs {
            try replaceTurnMembers(turnID: turn.identity.turnID, messageIDs: members)
        }
    }

    func replaceTurnMembers(turnID: UUID, messageIDs: [UUID]) throws {
        try executeUpdate("DELETE FROM turn_members WHERE turn_id = ?") {
            try bindText($0, 1, turnID.uuidString)
        }
        for (ordinal, messageID) in messageIDs.enumerated() {
            try executeUpdate(
                "INSERT INTO turn_members (turn_id, ord, message_id) VALUES (?, ?, ?)"
            ) {
                try bindText($0, 1, turnID.uuidString)
                try bindInt64($0, 2, Int64(ordinal))
                try bindText($0, 3, messageID.uuidString)
            }
        }
    }

    func loadTurn(id: UUID) throws -> TurnRecord? {
        guard let body = try queryText("SELECT body FROM turns WHERE turn_id = ?", bind: {
            try bindText($0, 1, id.uuidString)
        }) else { return nil }
        return try pkDecodeJSON(TurnRecord.self, from: body)
    }

    func requireTurn(id: UUID) throws -> TurnRecord {
        guard let turn = try loadTurn(id: id) else {
            throw TimelineRuntimeRepositoryError.turnNotFound(id)
        }
        return turn
    }

    func loadTurns(timelineID: UUID) throws -> [TurnRecord] {
        let statement = try prepare(
            "SELECT body FROM turns WHERE timeline_id = ? ORDER BY created_at ASC, turn_id ASC"
        )
        defer { finalize(statement) }
        try bindText(statement, 1, timelineID.uuidString)
        var turns: [TurnRecord] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            turns.append(try pkDecodeJSON(TurnRecord.self, from: body))
        }
        return turns
    }

    // MARK: Pointers

    func loadPointer(timelineID: UUID) throws -> (activeTurnID: UUID?, quarantinedTurnID: UUID?)? {
        let sql = "SELECT active_turn_id, quarantined_turn_id FROM timeline_pointers WHERE timeline_id = ?"
        let statement = try prepare(sql)
        defer { finalize(statement) }
        try bindText(statement, 1, timelineID.uuidString)
        guard try step(statement) else { return nil }
        let active = isNull(statement, 0) ? nil : text(statement, 0).flatMap(UUID.init(uuidString:))
        let quarantined = isNull(statement, 1) ? nil : text(statement, 1).flatMap(UUID.init(uuidString:))
        return (active, quarantined)
    }

    func upsertPointer(timelineID: UUID, active: UUID?, quarantined: UUID?) throws {
        try executeUpdate(
            """
            INSERT INTO timeline_pointers (timeline_id, active_turn_id, quarantined_turn_id)
            VALUES (?, ?, ?)
            ON CONFLICT(timeline_id) DO UPDATE SET
                active_turn_id = excluded.active_turn_id,
                quarantined_turn_id = excluded.quarantined_turn_id
            """
        ) {
            try bindText($0, 1, timelineID.uuidString)
            try bindText($0, 2, active?.uuidString)
            try bindText($0, 3, quarantined?.uuidString)
        }
    }

    // MARK: Tool rows

    func upsertToolIntent(_ intent: RuntimeToolIntent) throws {
        let body = try pkEncodeJSON(intent)
        try executeUpdate(
            """
            INSERT INTO tool_intents (turn_id, tool_call_id, timeline_id, created_at, body)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(turn_id, tool_call_id) DO UPDATE SET
                timeline_id = excluded.timeline_id,
                created_at = excluded.created_at,
                body = excluded.body
            """
        ) {
            try bindText($0, 1, intent.turnID.uuidString)
            try bindText($0, 2, intent.toolCallID)
            try bindText($0, 3, intent.timelineID.uuidString)
            try bindDouble($0, 4, intent.createdAt.timeIntervalSince1970)
            try bindText($0, 5, body)
        }
    }

    func upsertToolResult(_ result: RuntimeToolResult) throws {
        let body = try pkEncodeJSON(result)
        try executeUpdate(
            """
            INSERT INTO tool_results (turn_id, tool_call_id, timeline_id, created_at, body)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(turn_id, tool_call_id) DO UPDATE SET
                timeline_id = excluded.timeline_id,
                created_at = excluded.created_at,
                body = excluded.body
            """
        ) {
            try bindText($0, 1, result.turnID.uuidString)
            try bindText($0, 2, result.toolCallID)
            try bindText($0, 3, result.timelineID.uuidString)
            try bindDouble($0, 4, result.createdAt.timeIntervalSince1970)
            try bindText($0, 5, body)
        }
    }

    func loadToolIntents(turnID: UUID) throws -> [RuntimeToolIntent] {
        let statement = try prepare(
            "SELECT body FROM tool_intents WHERE turn_id = ? ORDER BY created_at ASC, tool_call_id ASC"
        )
        defer { finalize(statement) }
        try bindText(statement, 1, turnID.uuidString)
        var intents: [RuntimeToolIntent] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            intents.append(try pkDecodeJSON(RuntimeToolIntent.self, from: body))
        }
        return intents
    }

    func loadToolResults(turnID: UUID) throws -> [RuntimeToolResult] {
        let statement = try prepare(
            "SELECT body FROM tool_results WHERE turn_id = ? ORDER BY created_at ASC, tool_call_id ASC"
        )
        defer { finalize(statement) }
        try bindText(statement, 1, turnID.uuidString)
        var results: [RuntimeToolResult] = []
        while try step(statement) {
            guard let body = text(statement, 0) else { continue }
            results.append(try pkDecodeJSON(RuntimeToolResult.self, from: body))
        }
        return results
    }

    // MARK: Workspace bindings

    func loadBinding(workspaceID: UUID) throws -> WorkspaceBinding? {
        let sql = "SELECT workspace_id, timeline_id, created_at, updated_at FROM workspace_bindings WHERE workspace_id = ?"
        let statement = try prepare(sql)
        defer { finalize(statement) }
        try bindText(statement, 1, workspaceID.uuidString)
        guard try step(statement) else { return nil }
        return binding(from: statement)
    }

    func binding(from statement: OpaquePointer) -> WorkspaceBinding? {
        guard let workspaceID = text(statement, 0).flatMap(UUID.init(uuidString:)),
              let timelineID = text(statement, 1).flatMap(UUID.init(uuidString:))
        else { return nil }
        return WorkspaceBinding(
            workspaceID: workspaceID,
            timelineID: timelineID,
            createdAt: Date(timeIntervalSince1970: double(statement, 2)),
            updatedAt: Date(timeIntervalSince1970: double(statement, 3))
        )
    }

    func upsertBinding(_ binding: WorkspaceBinding) throws {
        try executeUpdate(
            """
            INSERT INTO workspace_bindings (workspace_id, timeline_id, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
                timeline_id = excluded.timeline_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """
        ) {
            try bindText($0, 1, binding.workspaceID.uuidString)
            try bindText($0, 2, binding.timelineID.uuidString)
            try bindDouble($0, 3, binding.createdAt.timeIntervalSince1970)
            try bindDouble($0, 4, binding.updatedAt.timeIntervalSince1970)
        }
    }

    func deleteBinding(workspaceID: UUID) throws {
        try executeUpdate("DELETE FROM workspace_bindings WHERE workspace_id = ?") {
            try bindText($0, 1, workspaceID.uuidString)
        }
    }
}
