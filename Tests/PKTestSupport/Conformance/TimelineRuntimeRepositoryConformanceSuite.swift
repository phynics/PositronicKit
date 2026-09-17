import Foundation
import PositronicKit
internal import Testing

/// Runs the documented behavioral checks for a ``TimelineRuntimeRepository`` implementation.
public enum TimelineRuntimeRepositoryConformanceSuite {
    /// Runs the repository checks against a fresh repository for every scenario.
    ///
    /// - Parameter makeRepository: A factory that returns an isolated repository for one scenario.
    ///
    /// The suite records failures through Swift Testing expectations. It does not declare test
    /// functions, so the caller controls test discovery and can invoke it from its own test
    /// target.
    public static func run(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        try await runScenario("timeline.admission.input") {
            try await admissionPersistsInput(makeRepository: makeRepository)
        }
        try await runScenario("timeline.admission.message-free") {
            try await messageFreeAdmission(makeRepository: makeRepository)
        }
        try await runScenario("timeline.admission.serialization") {
            try await admissionSerializesTimeline(makeRepository: makeRepository)
        }
        try await runScenario("timeline.admission.invalid-input") {
            try await invalidInputCanBeRetried(makeRepository: makeRepository)
        }
        try await runScenario("timeline.admission.authority") {
            try await capturesAuthority(makeRepository: makeRepository)
        }
        try await runScenario("timeline.retry.linkage") {
            try await admitsLinkedRetry(makeRepository: makeRepository)
        }
        try await runScenario("timeline.tool.barrier") {
            try await enforcesToolBarrier(makeRepository: makeRepository)
        }
        try await runScenario("timeline.tool-result.atomicity") {
            try await commitsToolResultAndMessage(makeRepository: makeRepository)
        }
        try await runScenario("timeline.history.append-only") {
            try await preservesAppendOnlyHistory(makeRepository: makeRepository)
        }
        try await runScenario("timeline.history.ordering") {
            try await ordersHistoryByTimestampAndAppendOrder(makeRepository: makeRepository)
        }
        try await runScenario("timeline.completion.outcome") {
            try await completesTurnAtomically(makeRepository: makeRepository)
        }
        try await runScenario("timeline.completion.wrong-timeline") {
            try await rejectsWrongTimelineFinalMessage(makeRepository: makeRepository)
        }
        try await runScenario("timeline.interrupt.retryable") {
            try await interruptsRetryableTurn(makeRepository: makeRepository)
        }
        try await runScenario("timeline.interrupt.first-writer-wins") {
            try await interruptDefersToCommittedOutcome(makeRepository: makeRepository)
        }
        try await runScenario("timeline.quarantine.release") {
            try await quarantinesAndReleasesTimeline(makeRepository: makeRepository)
        }
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String {
            "\(id): \(String(describing: underlying))"
        }
    }

    private static func runScenario(
        _ id: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            if error is Testing.ExpectationFailedError {
                throw error
            }
            throw ScenarioError(id: id, underlying: error)
        }
    }

    private static func admissionPersistsInput(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "hello")

        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(10)
        )

        try #require(admission.disposition == .admitted, "timeline.admission.input.admitted")
        let active = try #require(
            try await repository.fetchActiveTurn(for: timelineID),
            "timeline.admission.input.active"
        )
        try #require(active == admission.turn, "timeline.admission.input.active-record")
        try #require(active.identity.requestID == requestID, "timeline.admission.input.request-id")
        try #require(active.timelineID == timelineID, "timeline.admission.input.timeline-id")
        try #require(try await repository.fetchTurn(id: active.identity.turnID) == admission.turn, "timeline.admission.input.durable-record")
        let messages = try await repository.fetchMessages(for: timelineID)
        try #require(messages.map(\.id) == [input.id], "timeline.admission.input.persisted")
        try #require(messages.first?.content == input.content, "timeline.admission.input.content")

        let joined = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(20)
        )
        try #require(joined.disposition == .joined, "timeline.admission.input.joined")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [input.id], "timeline.admission.input.no-duplicate")

        do {
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "message:changed",
                inputMessage: input,
                executionKind: .direct,
                capturedAgentID: nil,
                turnID: UUID(),
                now: fixedDate(30)
            )
            Issue.record("timeline.admission.input.idempotency-conflict-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .idempotencyConflict(requestID: requestID), "timeline.admission.input.idempotency-conflict")
        }
    }

    private static func messageFreeAdmission(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        _ = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "tool-output-only",
            inputMessage: nil,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(10)
        )

        try #require(try await repository.fetchMessages(for: timelineID).isEmpty, "timeline.admission.message-free.no-history")
    }

    private static func admissionSerializesTimeline(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        let first = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "message:a",
            inputMessage: nil,
            now: fixedDate(10)
        )
        try #require(first.disposition == .admitted, "timeline.admission.serialization.admitted")

        let joined = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "message:a",
            now: fixedDate(11)
        )
        try #require(joined.disposition == .joined, "timeline.admission.serialization.joined")
        try #require(joined.turn.identity.turnID == first.turn.identity.turnID, "timeline.admission.serialization.same-turn")

        do {
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "message:b",
                inputMessage: nil,
                now: fixedDate(12)
            )
            Issue.record("timeline.admission.serialization.busy-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(
                error == .timelineBusy(timelineID: timelineID, activeTurnID: first.turn.identity.turnID),
                "timeline.admission.serialization.busy-error"
            )
        }
    }

    private static func invalidInputCanBeRetried(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let wrongTimelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        let wrongInput = TimelineMessage(
            id: requestID,
            timelineID: wrongTimelineID,
            role: .user,
            content: "hello"
        )
        do {
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: "hello",
                inputMessage: wrongInput,
                now: fixedDate(10)
            )
            Issue.record("timeline.admission.invalid-input.must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(
                error == .inputMessageTimelineMismatch(
                    messageID: requestID,
                    expectedTimelineID: timelineID,
                    actualTimelineID: wrongTimelineID
                ),
                "timeline.admission.invalid-input.error"
            )
        }

        try #require(try await repository.fetchActiveTurn(for: timelineID) == nil, "timeline.admission.invalid-input.no-active-turn")
        try #require(try await repository.fetchMessages(for: timelineID).isEmpty, "timeline.admission.invalid-input.no-message")

        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "hello")
        let retry = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "hello",
            inputMessage: input,
            now: fixedDate(20)
        )
        try #require(retry.disposition == .admitted, "timeline.admission.invalid-input.retry-admitted")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [input.id], "timeline.admission.invalid-input.retry-message")
    }

    private static func capturesAuthority(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let requestID = UUID()
        let agentID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        let first = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "authority",
            inputMessage: nil,
            executionKind: .agentManaged,
            capturedAgentID: agentID,
            turnID: UUID(),
            now: fixedDate(10)
        )
        try #require(first.turn.executionKind == .agentManaged, "timeline.admission.authority.execution-kind")
        try #require(first.turn.capturedAgentID == agentID, "timeline.admission.authority.agent")

        let joined = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "authority",
            inputMessage: nil,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(20)
        )
        try #require(joined.turn.executionKind == .agentManaged, "timeline.admission.authority.immutable-kind")
        try #require(joined.turn.capturedAgentID == agentID, "timeline.admission.authority.immutable-agent")
    }

    private static func admitsLinkedRetry(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let firstRequestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        let first = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: firstRequestID,
            callerIntentFingerprint: "first",
            inputMessage: TimelineMessage(id: firstRequestID, timelineID: timelineID, role: .user, content: "first"),
            now: fixedDate(10)
        )
        _ = try await repository.failTurn(
            turnID: first.turn.identity.turnID,
            message: "provider failed",
            now: fixedDate(11)
        )

        let retryRequestID = UUID()
        let retryInput = TimelineMessage(id: retryRequestID, timelineID: timelineID, role: .user, content: "retry")
        let retry = try await repository.admitRetry(
            timelineID: timelineID,
            previousTurnID: first.turn.identity.turnID,
            requestID: retryRequestID,
            callerIntentFingerprint: "retry",
            inputMessage: retryInput,
            executionKind: .agentManaged,
            capturedAgentID: nil,
            turnID: UUID(),
            attempt: 2,
            now: fixedDate(20)
        )
        try #require(retry.disposition == .admitted, "timeline.retry.admitted")
        try #require(retry.turn.retryRelation?.retriedTurnID == first.turn.identity.turnID, "timeline.retry.previous-turn")
        try #require(retry.turn.retryRelation?.attempt == 2, "timeline.retry.attempt")

        let replay = try await repository.admitRetry(
            timelineID: timelineID,
            previousTurnID: first.turn.identity.turnID,
            requestID: retryRequestID,
            callerIntentFingerprint: "retry",
            inputMessage: retryInput,
            executionKind: .agentManaged,
            capturedAgentID: nil,
            turnID: UUID(),
            attempt: 2,
            now: fixedDate(30)
        )
        try #require(replay.disposition == .joined, "timeline.retry.joined")
        try #require(replay.turn.retryRelation == retry.turn.retryRelation, "timeline.retry.same-relation")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [firstRequestID, retryRequestID], "timeline.retry.no-duplicate-input")
    }

    private static func enforcesToolBarrier(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "tool",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        let intent = RuntimeToolIntent(
            turnID: turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: fixedDate(10)
        )
        try await repository.recordToolIntent(intent)

        do {
            try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1, now: fixedDate(11))
            Issue.record("timeline.tool-barrier.unresolved-intent-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .toolIntentRequired(turnID: turnID, toolCallID: "call-1"), "timeline.tool-barrier.error")
        }

        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            output: "ok",
            createdAt: fixedDate(12)
        ))
        try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1, now: fixedDate(13))
        try #require(try await repository.fetchToolIntents(turnID: turnID) == [intent], "timeline.tool-barrier.intent")
        try #require(try await repository.fetchToolResults(turnID: turnID).count == 1, "timeline.tool-barrier.result")
    }

    private static func commitsToolResultAndMessage(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "atomic-tool",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: fixedDate(10)
        ))
        let message = TimelineMessage(timelineID: timelineID, role: .tool, content: "ok", timestamp: fixedDate(12), toolCallID: "call-1")
        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            output: "ok",
            createdAt: fixedDate(12)
        ), message: message)

        let messages = try await repository.fetchMessages(for: timelineID)
        try #require(messages.map(\.id) == [message.id], "timeline.tool-result.message")
        try #require(messages.first?.content == message.content, "timeline.tool-result.message-content")
        try #require(try await repository.fetchToolResults(turnID: turnID).count == 1, "timeline.tool-result.result")
    }

    private static func preservesAppendOnlyHistory(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let messageID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let message = TimelineMessage(id: messageID, timelineID: timelineID, role: .user, content: "hello", timestamp: fixedDate(10))
        try await repository.saveMessage(message)
        try await repository.saveMessage(message)

        do {
            try await repository.saveMessage(TimelineMessage(
                id: messageID,
                timelineID: timelineID,
                role: .user,
                content: "changed",
                timestamp: fixedDate(11)
            ))
            Issue.record("timeline.history.append-only.must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .appendOnlyViolation(messageID: messageID), "timeline.history.append-only.error")
        }

        let summary = TimelineSummary(timelineID: timelineID, sourceMessageIDs: [messageID], text: "hello", createdAt: fixedDate(12), updatedAt: fixedDate(12))
        try await repository.saveSummary(summary)
        try #require(try await repository.fetchSummaries(for: timelineID) == [summary], "timeline.history.summary")

        let missingSourceID = UUID()
        do {
            try await repository.saveSummary(TimelineSummary(
                timelineID: timelineID,
                sourceMessageIDs: [missingSourceID],
                text: "missing",
                createdAt: fixedDate(13),
                updatedAt: fixedDate(13)
            ))
            Issue.record("timeline.history.summary-missing-source.must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .summarySourceMissing(messageID: missingSourceID), "timeline.history.summary-missing-source.error")
        }

        do {
            try await repository.deleteMessages(for: timelineID)
            Issue.record("timeline.history.delete-messages.must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .historyDeletionForbidden(timelineID: timelineID), "timeline.history.delete-messages.error")
        }

        try await repository.deleteTimeline(id: timelineID)
        try #require(try await repository.fetchMessages(for: timelineID).isEmpty, "timeline.history.delete-cascade.messages")
        try #require(try await repository.fetchSummaries(for: timelineID).isEmpty, "timeline.history.delete-cascade.summaries")
    }

    private static func interruptsRetryableTurn(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "recover", timestamp: fixedDate(10))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "recover",
            inputMessage: input,
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID

        guard case let .interrupted(record) = try await repository.interruptTurn(
            turnID: turnID,
            reason: "Turn owner stopped making progress.",
            disposition: .retryable,
            now: fixedDate(20)
        ) else {
            Issue.record("timeline.interrupt.retryable.interrupted")
            return
        }
        try #require(record.outcome == .interrupted(reason: "Turn owner stopped making progress."), "timeline.interrupt.retryable.outcome")
        try #require(record.isQuarantined == false, "timeline.interrupt.retryable.no-quarantine")
        try #require(try await repository.fetchActiveTurn(for: timelineID) == nil, "timeline.interrupt.retryable.no-active-turn")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [input.id], "timeline.interrupt.retryable.input")

        // A retryable interruption releases the Timeline: the same request ID may be retried as a
        // linked attempt, and admission of a distinct request is permitted.
        let retry = try await repository.admitRetry(
            timelineID: timelineID,
            previousTurnID: turnID,
            requestID: requestID,
            callerIntentFingerprint: "recover",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            attempt: 2,
            now: fixedDate(21)
        )
        try #require(retry.disposition == .admitted, "timeline.interrupt.retryable.retry-admitted")
        try #require(retry.turn.retryRelation?.retriedTurnID == turnID, "timeline.interrupt.retryable.retry-link")
    }

    private static func interruptDefersToCommittedOutcome(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "first-writer-wins",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        let completed = try await repository.completeTurn(
            turnID: turnID,
            outcome: .completed,
            finalMessage: nil,
            terminalHandle: TurnTerminalHandle(turnID: turnID),
            now: fixedDate(11)
        )

        guard case let .alreadyTerminal(record) = try await repository.interruptTurn(
            turnID: turnID,
            reason: "Late interruption after completion.",
            disposition: .retryable,
            now: fixedDate(12)
        ) else {
            Issue.record("timeline.interrupt.first-writer-wins.already-terminal")
            return
        }
        try #require(record == completed, "timeline.interrupt.first-writer-wins.record-unchanged")
        try #require(try await repository.fetchTurn(id: turnID) == completed, "timeline.interrupt.first-writer-wins.durable-unchanged")
    }

    private static func quarantinesAndReleasesTimeline(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "side-effect",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        let intent = RuntimeToolIntent(
            turnID: turnID,
            timelineID: timelineID,
            toolCallID: "call-1",
            name: "write-file",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: fixedDate(10)
        )
        try await repository.recordToolIntent(intent)

        guard case let .interrupted(record) = try await repository.interruptTurn(
            turnID: turnID,
            reason: "Turn owner abandoned an in-flight mutating tool.",
            disposition: .quarantined("Unresolved mutating tool intent call-1."),
            now: fixedDate(11)
        ) else {
            Issue.record("timeline.quarantine.release.interrupted")
            return
        }
        try #require(record.isQuarantined, "timeline.quarantine.release.marker")
        try #require(record.quarantine?.reason == "Unresolved mutating tool intent call-1.", "timeline.quarantine.release.reason")
        try #require(try await repository.fetchToolIntents(turnID: turnID) == [intent], "timeline.quarantine.release.intent")

        do {
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "new-request",
                inputMessage: TimelineMessage(timelineID: timelineID, role: .user, content: "new"),
                now: fixedDate(12)
            )
            Issue.record("timeline.quarantine.release.admission-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .timelineQuarantined(timelineID: timelineID, turnID: turnID), "timeline.quarantine.release.admission-error")
        }

        do {
            _ = try await repository.releaseQuarantine(
                timelineID: timelineID,
                turnID: turnID,
                confirmation: QuarantineReleaseConfirmation(phrase: "yes"),
                now: fixedDate(13)
            )
            Issue.record("timeline.quarantine.release.confirmation-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .confirmationRequired, "timeline.quarantine.release.confirmation-error")
        }

        let released = try await repository.releaseQuarantine(
            timelineID: timelineID,
            turnID: turnID,
            confirmation: QuarantineReleaseConfirmation(phrase: QuarantineReleaseConfirmation.requiredPhrase),
            now: fixedDate(14)
        )
        try #require(released.isQuarantined == false, "timeline.quarantine.release.cleared")
        try #require(try await repository.fetchTurn(id: turnID)?.isQuarantined == false, "timeline.quarantine.release.durable-cleared")

        // Releasing a Turn that is no longer quarantined must report the opposite of
        // "quarantined", not re-use `timelineQuarantined`.
        do {
            _ = try await repository.releaseQuarantine(
                timelineID: timelineID,
                turnID: turnID,
                confirmation: QuarantineReleaseConfirmation(phrase: QuarantineReleaseConfirmation.requiredPhrase),
                now: fixedDate(15)
            )
            Issue.record("timeline.quarantine.release.not-found-must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(error == .quarantineNotFound(timelineID: timelineID, turnID: turnID), "timeline.quarantine.release.not-found-error")
        }

        let admitted = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "new-request",
            inputMessage: TimelineMessage(timelineID: timelineID, role: .user, content: "new"),
            now: fixedDate(15)
        )
        try #require(admitted.disposition == .admitted, "timeline.quarantine.release.admission-after-release")
    }

    private static func ordersHistoryByTimestampAndAppendOrder(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID(uuidString: "00000000-0000-0000-0000-000000000166")!
        try await repository.saveTimeline(TimelineRecord(id: timelineID))

        let earliest = TimelineMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            timelineID: timelineID,
            role: .user,
            content: "earliest",
            timestamp: fixedDate(10)
        )
        let equalFirst = TimelineMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            timelineID: timelineID,
            role: .user,
            content: "equal first",
            timestamp: fixedDate(20)
        )
        let equalSecond = TimelineMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            timelineID: timelineID,
            role: .user,
            content: "equal second",
            timestamp: fixedDate(20)
        )
        let latest = TimelineMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            timelineID: timelineID,
            role: .user,
            content: "latest",
            timestamp: fixedDate(30)
        )

        for message in [equalFirst, latest, equalSecond, earliest] {
            try await repository.saveMessage(message)
        }

        let messages = try await repository.fetchMessages(for: timelineID)
        try #require(
            messages.map(\.id) == [earliest.id, equalFirst.id, equalSecond.id, latest.id],
            "timeline.history.ordering.timestamp-then-append"
        )
        try #require(
            try await repository.fetchMessages(for: UUID(uuidString: "00000000-0000-0000-0000-000000000199")!).isEmpty,
            "timeline.history.ordering.unknown-timeline"
        )
    }

    private static func completesTurnAtomically(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "terminal",
            now: fixedDate(10)
        )
        let terminalMessage = TimelineMessage(timelineID: timelineID, role: .assistant, content: "done", timestamp: fixedDate(11))
        let terminalHandle = TurnTerminalHandle(turnID: admission.turn.identity.turnID)
        let completed = try await repository.completeTurn(
            turnID: admission.turn.identity.turnID,
            outcome: .completed,
            finalMessage: terminalMessage,
            terminalHandle: terminalHandle,
            now: fixedDate(12)
        )
        try #require(completed.outcome == .completed, "timeline.completion.outcome")
        try #require(completed.terminalHandle == terminalHandle, "timeline.completion.handle")
        try #require(completed.terminalMessageID == terminalMessage.id, "timeline.completion.message-id")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [terminalMessage.id], "timeline.completion.message")
        try #require(try await repository.fetchActiveTurn(for: timelineID) == nil, "timeline.completion.no-active-turn")

        let repeated = try await repository.completeTurn(
            turnID: admission.turn.identity.turnID,
            outcome: .completed,
            finalMessage: terminalMessage,
            terminalHandle: terminalHandle,
            now: fixedDate(13)
        )
        try #require(repeated == completed, "timeline.completion.idempotent-record")
        try #require(try await repository.fetchMessages(for: timelineID).map(\.id) == [terminalMessage.id], "timeline.completion.idempotent-message")
    }

    private static func rejectsWrongTimelineFinalMessage(
        makeRepository: () async throws -> any TimelineRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let timelineID = UUID()
        let otherTimelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        try await repository.saveTimeline(TimelineRecord(id: otherTimelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "wrong-timeline",
            now: fixedDate(10)
        )
        let finalMessage = TimelineMessage(timelineID: otherTimelineID, role: .assistant, content: "wrong history", timestamp: fixedDate(11))

        do {
            _ = try await repository.completeTurn(
                turnID: admission.turn.identity.turnID,
                outcome: .completed,
                finalMessage: finalMessage,
                terminalHandle: nil,
                now: fixedDate(12)
            )
            Issue.record("timeline.completion.wrong-timeline.must-fail")
            return
        } catch let error as TimelineRuntimeRepositoryError {
            try #require(
                error == .finalMessageTimelineMismatch(
                    messageID: finalMessage.id,
                    expectedTimelineID: timelineID,
                    actualTimelineID: otherTimelineID
                ),
                "timeline.completion.wrong-timeline.error"
            )
        }

        let persistedTurn = try #require(try await repository.fetchTurn(id: admission.turn.identity.turnID), "timeline.completion.wrong-timeline.turn")
        try #require(persistedTurn.outcome == nil, "timeline.completion.wrong-timeline.no-outcome")
        try #require(try await repository.fetchMessages(for: timelineID).isEmpty, "timeline.completion.wrong-timeline.no-target-message")
        try #require(try await repository.fetchMessages(for: otherTimelineID).isEmpty, "timeline.completion.wrong-timeline.no-source-message")
        try #require(try await repository.fetchActiveTurn(for: timelineID)?.identity.turnID == admission.turn.identity.turnID, "timeline.completion.wrong-timeline.remains-active")
    }

    private static func fixedDate(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
