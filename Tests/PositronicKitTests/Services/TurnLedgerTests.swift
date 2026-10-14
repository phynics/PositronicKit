import Foundation
import PKContracts
import PositronicKit
import Testing

/// The Turn ledger rules as pure decisions over a loaded snapshot: no actor, no adapter, and no
/// storage. These tests pin the rows each decision tells an adapter to write.
@Suite("Turn ledger decisions")
struct TurnLedgerTests {
    private let timelineID = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("admission is one atomic set of rows")
    func admissionIsAtomic() throws {
        let requestID = UUID()
        let turnID = UUID()
        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "hello")

        let decision = try TurnLedger.decideAdmission(
            snapshot: TurnLedgerSnapshot(timelineExists: true),
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "hello",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: turnID,
            now: now
        )

        #expect(decision.result.disposition == .admitted)
        #expect(decision.result.turn.identity.turnID == turnID)
        #expect(decision.commit.upsertedTurns.map(\.identity.turnID) == [turnID])
        #expect(decision.commit.appendedMessages.map(\.id) == [input.id])
        #expect(decision.commit.pointerTimelineID == timelineID)
        #expect(decision.commit.activeTurnID == turnID)
    }

    @Test("a retry of the same intent joins without writing rows")
    func idempotentAdmissionJoins() throws {
        let requestID = UUID()
        let admitted = try admit(requestID: requestID, fingerprint: "hello").result.turn
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [admitted],
            activeTurnID: admitted.identity.turnID
        )

        let joined = try TurnLedger.decideAdmission(
            snapshot: snapshot,
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "hello",
            inputMessage: nil,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: now
        )

        #expect(joined.result.disposition == .joined)
        #expect(joined.result.turn == admitted)
        #expect(joined.commit.upsertedTurns.isEmpty)
        #expect(joined.commit.pointerTimelineID == nil)
    }

    @Test("a reused Request ID with a different fingerprint is a conflict")
    func fingerprintConflict() throws {
        let requestID = UUID()
        let admitted = try admit(requestID: requestID, fingerprint: "hello").result.turn
        let snapshot = TurnLedgerSnapshot(timelineExists: true, turns: [admitted])

        #expect(throws: TimelineRuntimeRepositoryError.idempotencyConflict(requestID: requestID)) {
            _ = try TurnLedger.decideAdmission(
                snapshot: snapshot,
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "changed",
                inputMessage: nil,
                executionKind: .direct,
                capturedAgentID: nil,
                turnID: UUID(),
                now: now
            )
        }
    }

    @Test("a busy Timeline rejects a distinct request")
    func busyTimelineRejects() throws {
        let active = try admit(requestID: UUID(), fingerprint: "first").result.turn
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [active],
            activeTurnID: active.identity.turnID
        )

        #expect(throws: TimelineRuntimeRepositoryError.timelineBusy(
            timelineID: timelineID,
            activeTurnID: active.identity.turnID
        )) {
            _ = try TurnLedger.decideAdmission(
                snapshot: snapshot,
                timelineID: timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "second",
                inputMessage: nil,
                executionKind: .direct,
                capturedAgentID: nil,
                turnID: UUID(),
                now: now
            )
        }
    }

    @Test("a quarantined Timeline rejects admission")
    func quarantinedTimelineRejects() throws {
        let quarantined = turn(lifecycle: .interrupted, quarantine: TurnQuarantine(reason: "side effect", createdAt: now))
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [quarantined],
            quarantinedTurnID: quarantined.identity.turnID
        )

        #expect(throws: TimelineRuntimeRepositoryError.timelineQuarantined(
            timelineID: timelineID,
            turnID: quarantined.identity.turnID
        )) {
            _ = try TurnLedger.decideAdmission(
                snapshot: snapshot,
                timelineID: timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "new",
                inputMessage: nil,
                executionKind: .direct,
                capturedAgentID: nil,
                turnID: UUID(),
                now: now
            )
        }
    }

    @Test("the tool barrier rejects a round with an unresolved intent")
    func toolBarrierRejectsUnresolvedIntent() throws {
        let admitted = try admit(requestID: UUID(), fingerprint: "tool").result.turn
        let intent = RuntimeToolIntent(
            turnID: admitted.identity.turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: now
        )
        let blocked = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [admitted],
            activeTurnID: admitted.identity.turnID,
            toolIntents: [intent]
        )

        #expect(throws: TimelineRuntimeRepositoryError.toolIntentRequired(
            turnID: admitted.identity.turnID,
            toolCallID: "call-1"
        )) {
            _ = try TurnLedger.decideBeginModelRound(
                snapshot: blocked,
                turnID: admitted.identity.turnID,
                modelRoundIndex: 1,
                now: now
            )
        }

        let resolved = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [admitted],
            activeTurnID: admitted.identity.turnID,
            toolIntents: [intent],
            toolResults: [RuntimeToolResult(
                turnID: admitted.identity.turnID,
                timelineID: timelineID,
                toolCallID: "call-1",
                output: "ok",
                createdAt: now
            )]
        )
        let advanced = try TurnLedger.decideBeginModelRound(
            snapshot: resolved,
            turnID: admitted.identity.turnID,
            modelRoundIndex: 1,
            now: now
        )
        #expect(advanced.commit.upsertedTurns.first?.currentModelRoundIndex == 1)
    }

    @Test("the tool message and result commit in one decision")
    func toolResultCommitsMessageAndResult() throws {
        let admitted = try admit(requestID: UUID(), fingerprint: "tool").result.turn
        let intent = RuntimeToolIntent(
            turnID: admitted.identity.turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: now
        )
        let message = TimelineMessage(timelineID: timelineID, role: .tool, content: "ok", toolCallID: "call-1")
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [admitted],
            activeTurnID: admitted.identity.turnID,
            toolIntents: [intent]
        )

        let decision = try TurnLedger.decideRecordToolResult(
            snapshot: snapshot,
            result: RuntimeToolResult(
                turnID: admitted.identity.turnID,
                timelineID: timelineID,
                toolCallID: "call-1",
                output: "ok",
                createdAt: now
            ),
            message: message
        )

        #expect(decision.commit.appendedMessages.map(\.id) == [message.id])
        #expect(decision.commit.upsertedToolResults.count == 1)
        #expect(decision.commit.upsertedTurns.first?.memberMessageIDs == [admitted.identity.requestID, message.id])
    }

    @Test("terminal completion is first-writer-wins")
    func completionIsFirstWriterWins() throws {
        let completed = turn(lifecycle: .completed, outcome: .completed)
        let snapshot = TurnLedgerSnapshot(timelineExists: true, turns: [completed])

        let decision = try TurnLedger.decideCompleteTurn(
            snapshot: snapshot,
            turnID: completed.identity.turnID,
            outcome: .failed(message: "late"),
            finalMessage: nil,
            terminalHandle: nil,
            now: now
        )

        #expect(decision.result == completed)
        #expect(decision.commit.upsertedTurns.isEmpty)
        #expect(decision.commit.pointerTimelineID == nil)
    }

    @Test("quarantine release clears the marker only for the owning Turn")
    func quarantineRelease() throws {
        let quarantined = turn(lifecycle: .interrupted, quarantine: TurnQuarantine(reason: "side effect", createdAt: now))
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [quarantined],
            quarantinedTurnID: quarantined.identity.turnID
        )

        #expect(throws: TimelineRuntimeRepositoryError.confirmationRequired) {
            _ = try TurnLedger.decideReleaseQuarantine(
                snapshot: snapshot,
                timelineID: timelineID,
                turnID: quarantined.identity.turnID,
                confirmation: QuarantineReleaseConfirmation(phrase: "yes"),
                now: now
            )
        }

        let released = try TurnLedger.decideReleaseQuarantine(
            snapshot: snapshot,
            timelineID: timelineID,
            turnID: quarantined.identity.turnID,
            confirmation: QuarantineReleaseConfirmation(phrase: QuarantineReleaseConfirmation.requiredPhrase),
            now: now
        )
        #expect(released.result.isQuarantined == false)
        #expect(released.commit.quarantinedTurnID == nil)
        #expect(released.commit.pointerTimelineID == timelineID)
    }

    @Test("committing a message records it once in membership order")
    func membershipOrdering() throws {
        let admitted = try admit(requestID: UUID(), fingerprint: "m").result.turn
        let intermediate = TimelineMessage(timelineID: timelineID, role: .assistant, content: "tool call")
        let snapshot = TurnLedgerSnapshot(
            timelineExists: true,
            turns: [admitted],
            messages: [TimelineMessage(id: admitted.identity.requestID, timelineID: timelineID, role: .user, content: "input")],
            activeTurnID: admitted.identity.turnID
        )

        let first = try TurnLedger.decideRecordTurnMessage(
            snapshot: snapshot,
            turnID: admitted.identity.turnID,
            message: intermediate
        )
        #expect(first.commit.upsertedTurns.first?.memberMessageIDs == [admitted.identity.requestID, intermediate.id])
        #expect(first.commit.appendedMessages.map(\.id) == [intermediate.id])
    }

    // MARK: Fixtures

    private func admit(requestID: UUID, fingerprint: String) throws -> TurnLedgerDecision<TurnAdmission> {
        try TurnLedger.decideAdmission(
            snapshot: TurnLedgerSnapshot(timelineExists: true),
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: fingerprint,
            inputMessage: TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: fingerprint),
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: now
        )
    }

    private func turn(
        lifecycle: TurnLifecycle,
        outcome: TurnOutcome? = nil,
        quarantine: TurnQuarantine? = nil
    ) -> TurnRecord {
        TurnRecord(
            identity: TurnIdentity(turnID: UUID(), requestID: UUID(), modelRoundIndex: 0),
            timelineID: timelineID,
            callerIntent: TurnCallerIntent(requestID: UUID(), fingerprint: "fixture"),
            lifecycle: lifecycle,
            outcome: outcome,
            quarantine: quarantine,
            createdAt: now,
            updatedAt: now
        )
    }
}
