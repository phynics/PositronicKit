import Foundation
import PositronicKit
internal import Testing

/// Runs the documented behavioral checks for a ``ThreadRuntimeRepository`` implementation.
public enum ThreadRuntimeRepositoryConformanceSuite {
    /// Runs the repository checks against a fresh repository for every scenario.
    ///
    /// - Parameters:
    ///   - staleAfter: The stale interval configured by the repository. The recovery scenario
    ///     advances a fixed timestamp beyond this interval.
    ///   - makeRepository: A factory that returns an isolated repository for one scenario.
    ///
    /// The suite records failures through Swift Testing expectations. It does not declare test
    /// functions, so the caller controls test discovery and can invoke it from its own test
    /// target.
    public static func run(
        staleAfter: TimeInterval,
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        try #require(staleAfter.isFinite && staleAfter >= 0, "thread.configuration.stale-after")

        try await runScenario("thread.admission.input") {
            try await admissionPersistsInput(makeRepository: makeRepository)
        }
        try await runScenario("thread.admission.message-free") {
            try await messageFreeAdmission(makeRepository: makeRepository)
        }
        try await runScenario("thread.admission.serialization") {
            try await admissionSerializesThread(makeRepository: makeRepository)
        }
        try await runScenario("thread.admission.invalid-input") {
            try await invalidInputCanBeRetried(makeRepository: makeRepository)
        }
        try await runScenario("thread.admission.authority") {
            try await capturesAuthority(makeRepository: makeRepository)
        }
        try await runScenario("thread.retry.linkage") {
            try await admitsLinkedRetry(makeRepository: makeRepository)
        }
        try await runScenario("thread.tool.barrier") {
            try await enforcesToolBarrier(makeRepository: makeRepository)
        }
        try await runScenario("thread.tool-result.atomicity") {
            try await commitsToolResultAndMessage(makeRepository: makeRepository)
        }
        try await runScenario("thread.history.append-only") {
            try await preservesAppendOnlyHistory(makeRepository: makeRepository)
        }
        try await runScenario("thread.recovery.stale") {
            try await recoversStaleTurn(makeRepository: makeRepository, staleAfter: staleAfter)
        }
        try await runScenario("thread.force-clear.confirmation") {
            try await requiresForceClearConfirmation(makeRepository: makeRepository)
        }
        try await runScenario("thread.completion.outcome") {
            try await completesTurnAtomically(makeRepository: makeRepository)
        }
        try await runScenario("thread.completion.wrong-thread") {
            try await rejectsWrongThreadFinalMessage(makeRepository: makeRepository)
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
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let requestID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let input = ThreadMessage(id: requestID, threadID: threadID, role: .user, content: "hello")

        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(10)
        )

        try #require(admission.disposition == .admitted, "thread.admission.input.admitted")
        let active = try #require(
            try await repository.fetchActiveTurn(for: threadID),
            "thread.admission.input.active"
        )
        try #require(active == admission.turn, "thread.admission.input.active-record")
        try #require(active.identity.requestID == requestID, "thread.admission.input.request-id")
        try #require(active.threadID == threadID, "thread.admission.input.thread-id")
        try #require(try await repository.fetchTurn(id: active.identity.turnID) == admission.turn, "thread.admission.input.durable-record")
        let messages = try await repository.fetchMessages(for: threadID)
        try #require(messages.map(\.id) == [input.id], "thread.admission.input.persisted")
        try #require(messages.first?.content == input.content, "thread.admission.input.content")

        let joined = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(20)
        )
        try #require(joined.disposition == .joined, "thread.admission.input.joined")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [input.id], "thread.admission.input.no-duplicate")

        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: requestID,
                callerIntentFingerprint: "message:changed",
                inputMessage: input,
                executionKind: .direct,
                capturedAgentID: nil,
                turnID: UUID(),
                now: fixedDate(30)
            )
            Issue.record("thread.admission.input.idempotency-conflict-must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .idempotencyConflict(requestID: requestID), "thread.admission.input.idempotency-conflict")
        }
    }

    private static func messageFreeAdmission(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))

        _ = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "tool-output-only",
            inputMessage: nil,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(10)
        )

        try #require(try await repository.fetchMessages(for: threadID).isEmpty, "thread.admission.message-free.no-history")
    }

    private static func admissionSerializesThread(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let requestID = UUID()
        try await repository.saveThread(Thread(id: threadID))

        let first = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:a",
            inputMessage: nil,
            now: fixedDate(10)
        )
        try #require(first.disposition == .admitted, "thread.admission.serialization.admitted")

        let joined = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:a",
            now: fixedDate(11)
        )
        try #require(joined.disposition == .joined, "thread.admission.serialization.joined")
        try #require(joined.turn.identity.turnID == first.turn.identity.turnID, "thread.admission.serialization.same-turn")

        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: UUID(),
                callerIntentFingerprint: "message:b",
                inputMessage: nil,
                now: fixedDate(12)
            )
            Issue.record("thread.admission.serialization.busy-must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(
                error == .threadBusy(threadID: threadID, activeTurnID: first.turn.identity.turnID),
                "thread.admission.serialization.busy-error"
            )
        }
    }

    private static func invalidInputCanBeRetried(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let wrongThreadID = UUID()
        let requestID = UUID()
        try await repository.saveThread(Thread(id: threadID))

        let wrongInput = ThreadMessage(
            id: requestID,
            threadID: wrongThreadID,
            role: .user,
            content: "hello"
        )
        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: requestID,
                callerIntentFingerprint: "hello",
                inputMessage: wrongInput,
                now: fixedDate(10)
            )
            Issue.record("thread.admission.invalid-input.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(
                error == .inputMessageThreadMismatch(
                    messageID: requestID,
                    expectedThreadID: threadID,
                    actualThreadID: wrongThreadID
                ),
                "thread.admission.invalid-input.error"
            )
        }

        try #require(try await repository.fetchActiveTurn(for: threadID) == nil, "thread.admission.invalid-input.no-active-turn")
        try #require(try await repository.fetchMessages(for: threadID).isEmpty, "thread.admission.invalid-input.no-message")

        let input = ThreadMessage(id: requestID, threadID: threadID, role: .user, content: "hello")
        let retry = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "hello",
            inputMessage: input,
            now: fixedDate(20)
        )
        try #require(retry.disposition == .admitted, "thread.admission.invalid-input.retry-admitted")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [input.id], "thread.admission.invalid-input.retry-message")
    }

    private static func capturesAuthority(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let requestID = UUID()
        let agentID = UUID()
        try await repository.saveThread(Thread(id: threadID))

        let first = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "authority",
            inputMessage: nil,
            executionKind: .agentManaged,
            capturedAgentID: agentID,
            turnID: UUID(),
            now: fixedDate(10)
        )
        try #require(first.turn.executionKind == .agentManaged, "thread.admission.authority.execution-kind")
        try #require(first.turn.capturedAgentID == agentID, "thread.admission.authority.agent")

        let joined = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "authority",
            inputMessage: nil,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: fixedDate(20)
        )
        try #require(joined.turn.executionKind == .agentManaged, "thread.admission.authority.immutable-kind")
        try #require(joined.turn.capturedAgentID == agentID, "thread.admission.authority.immutable-agent")
    }

    private static func admitsLinkedRetry(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let firstRequestID = UUID()
        try await repository.saveThread(Thread(id: threadID))

        let first = try await repository.admitTurn(
            threadID: threadID,
            requestID: firstRequestID,
            callerIntentFingerprint: "first",
            inputMessage: ThreadMessage(id: firstRequestID, threadID: threadID, role: .user, content: "first"),
            now: fixedDate(10)
        )
        _ = try await repository.failTurn(
            turnID: first.turn.identity.turnID,
            message: "provider failed",
            now: fixedDate(11)
        )

        let retryRequestID = UUID()
        let retryInput = ThreadMessage(id: retryRequestID, threadID: threadID, role: .user, content: "retry")
        let retry = try await repository.admitRetry(
            threadID: threadID,
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
        try #require(retry.disposition == .admitted, "thread.retry.admitted")
        try #require(retry.turn.retryRelation?.retriedTurnID == first.turn.identity.turnID, "thread.retry.previous-turn")
        try #require(retry.turn.retryRelation?.attempt == 2, "thread.retry.attempt")

        let replay = try await repository.admitRetry(
            threadID: threadID,
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
        try #require(replay.disposition == .joined, "thread.retry.joined")
        try #require(replay.turn.retryRelation == retry.turn.retryRelation, "thread.retry.same-relation")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [firstRequestID, retryRequestID], "thread.retry.no-duplicate-input")
    }

    private static func enforcesToolBarrier(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "tool",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        let intent = RuntimeToolIntent(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: fixedDate(10)
        )
        try await repository.recordToolIntent(intent)

        do {
            try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1, now: fixedDate(11))
            Issue.record("thread.tool-barrier.unresolved-intent-must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .toolIntentRequired(turnID: turnID, toolCallID: "call-1"), "thread.tool-barrier.error")
        }

        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            output: "ok",
            createdAt: fixedDate(12)
        ))
        try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1, now: fixedDate(13))
        try #require(try await repository.fetchToolIntents(turnID: turnID) == [intent], "thread.tool-barrier.intent")
        try #require(try await repository.fetchToolResults(turnID: turnID).count == 1, "thread.tool-barrier.result")
    }

    private static func commitsToolResultAndMessage(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "atomic-tool",
            now: fixedDate(10)
        )
        let turnID = admission.turn.identity.turnID
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: fixedDate(10)
        ))
        let message = ThreadMessage(threadID: threadID, role: .tool, content: "ok", timestamp: fixedDate(12), toolCallID: "call-1")
        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            output: "ok",
            createdAt: fixedDate(12)
        ), message: message)

        let messages = try await repository.fetchMessages(for: threadID)
        try #require(messages.map(\.id) == [message.id], "thread.tool-result.message")
        try #require(messages.first?.content == message.content, "thread.tool-result.message-content")
        try #require(try await repository.fetchToolResults(turnID: turnID).count == 1, "thread.tool-result.result")
    }

    private static func preservesAppendOnlyHistory(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let messageID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let message = ThreadMessage(id: messageID, threadID: threadID, role: .user, content: "hello", timestamp: fixedDate(10))
        try await repository.saveMessage(message)
        try await repository.saveMessage(message)

        do {
            try await repository.saveMessage(ThreadMessage(
                id: messageID,
                threadID: threadID,
                role: .user,
                content: "changed",
                timestamp: fixedDate(11)
            ))
            Issue.record("thread.history.append-only.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .appendOnlyViolation(messageID: messageID), "thread.history.append-only.error")
        }

        let summary = ThreadSummary(threadID: threadID, sourceMessageIDs: [messageID], text: "hello", createdAt: fixedDate(12), updatedAt: fixedDate(12))
        try await repository.saveSummary(summary)
        try #require(try await repository.fetchSummaries(for: threadID) == [summary], "thread.history.summary")

        let missingSourceID = UUID()
        do {
            try await repository.saveSummary(ThreadSummary(
                threadID: threadID,
                sourceMessageIDs: [missingSourceID],
                text: "missing",
                createdAt: fixedDate(13),
                updatedAt: fixedDate(13)
            ))
            Issue.record("thread.history.summary-missing-source.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .summarySourceMissing(messageID: missingSourceID), "thread.history.summary-missing-source.error")
        }

        do {
            try await repository.deleteMessages(for: threadID)
            Issue.record("thread.history.delete-messages.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .historyDeletionForbidden(threadID: threadID), "thread.history.delete-messages.error")
        }

        try await repository.deleteThread(id: threadID)
        try #require(try await repository.fetchMessages(for: threadID).isEmpty, "thread.history.delete-cascade.messages")
        try #require(try await repository.fetchSummaries(for: threadID).isEmpty, "thread.history.delete-cascade.summaries")
    }

    private static func recoversStaleTurn(
        makeRepository: () async throws -> any ThreadRuntimeRepository,
        staleAfter: TimeInterval
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let requestID = UUID()
        let admissionDate = fixedDate(10)
        let recoveryDate = admissionDate.addingTimeInterval(staleAfter + 1)
        try await repository.saveThread(Thread(id: threadID))
        let input = ThreadMessage(id: requestID, threadID: threadID, role: .user, content: "recover", timestamp: admissionDate)
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "recover",
            inputMessage: input,
            now: admissionDate
        )
        let intent = RuntimeToolIntent(
            turnID: admission.turn.identity.turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: admissionDate
        )
        try await repository.recordToolIntent(intent)

        guard case let .recoveryRequired(record) = try await repository.recover(threadID: threadID, now: recoveryDate) else {
            Issue.record("thread.recovery.stale.required")
            return
        }
        try #require(record.recoveryRequired, "thread.recovery.stale.marker")
        try #require(try await repository.fetchToolIntents(turnID: record.identity.turnID) == [intent], "thread.recovery.stale.intent")
        try #require(try await repository.fetchActiveTurn(for: threadID) == nil, "thread.recovery.stale.no-active-turn")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [input.id], "thread.recovery.stale.input")

        let replay = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "recover",
            inputMessage: input,
            now: recoveryDate.addingTimeInterval(1)
        )
        try #require(replay.disposition == .replayed, "thread.recovery.replay")
        try #require(replay.turn.identity.turnID == record.identity.turnID, "thread.recovery.replay.same-turn")

        guard case let .recoveryRequired(repeatedRecord) = try await repository.recover(
            threadID: threadID,
            now: recoveryDate.addingTimeInterval(2)
        ) else {
            Issue.record("thread.recovery.stale.remains-required")
            return
        }
        try #require(repeatedRecord.identity.turnID == record.identity.turnID, "thread.recovery.stale.same-turn")

        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: UUID(),
                callerIntentFingerprint: "new-request",
                inputMessage: ThreadMessage(threadID: threadID, role: .user, content: "new"),
                now: recoveryDate.addingTimeInterval(1)
            )
            Issue.record("thread.recovery.distinct-request.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .recoveryRequired(threadID: threadID, turnID: record.identity.turnID), "thread.recovery.distinct-request.error")
        }
    }

    private static func requiresForceClearConfirmation(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        _ = try await repository.admitTurn(threadID: threadID, requestID: UUID(), callerIntentFingerprint: "admin", now: fixedDate(10))

        do {
            _ = try await repository.forceClear(
                threadID: threadID,
                confirmation: ForceClearConfirmation(phrase: "yes"),
                now: fixedDate(11)
            )
            Issue.record("thread.force-clear.confirmation.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(error == .confirmationRequired, "thread.force-clear.confirmation.error")
        }

        let cleared = try await repository.forceClear(
            threadID: threadID,
            confirmation: ForceClearConfirmation(phrase: ForceClearConfirmation.requiredPhrase),
            now: fixedDate(12)
        )
        let clearedTurnID = try #require(cleared?.identity.turnID, "thread.force-clear.record")
        try #require(try await repository.fetchActiveTurn(for: threadID) == nil, "thread.force-clear.no-active-turn")
        try #require(try await repository.fetchTurn(id: clearedTurnID) != nil, "thread.force-clear.preserved-turn")
        guard case .recoveryRequired = try await repository.recover(threadID: threadID, now: fixedDate(13)) else {
            Issue.record("thread.force-clear.recovery-marker")
            return
        }
    }

    private static func completesTurnAtomically(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "terminal",
            now: fixedDate(10)
        )
        let terminalMessage = ThreadMessage(threadID: threadID, role: .assistant, content: "done", timestamp: fixedDate(11))
        let terminalHandle = TurnTerminalHandle(turnID: admission.turn.identity.turnID)
        let completed = try await repository.completeTurn(
            turnID: admission.turn.identity.turnID,
            outcome: .completed,
            finalMessage: terminalMessage,
            terminalHandle: terminalHandle,
            now: fixedDate(12)
        )
        try #require(completed.outcome == .completed, "thread.completion.outcome")
        try #require(completed.terminalHandle == terminalHandle, "thread.completion.handle")
        try #require(completed.terminalMessageID == terminalMessage.id, "thread.completion.message-id")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [terminalMessage.id], "thread.completion.message")
        try #require(try await repository.fetchActiveTurn(for: threadID) == nil, "thread.completion.no-active-turn")

        let repeated = try await repository.completeTurn(
            turnID: admission.turn.identity.turnID,
            outcome: .completed,
            finalMessage: terminalMessage,
            terminalHandle: terminalHandle,
            now: fixedDate(13)
        )
        try #require(repeated == completed, "thread.completion.idempotent-record")
        try #require(try await repository.fetchMessages(for: threadID).map(\.id) == [terminalMessage.id], "thread.completion.idempotent-message")
    }

    private static func rejectsWrongThreadFinalMessage(
        makeRepository: () async throws -> any ThreadRuntimeRepository
    ) async throws {
        let repository = try await makeRepository()
        let threadID = UUID()
        let otherThreadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        try await repository.saveThread(Thread(id: otherThreadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "wrong-thread",
            now: fixedDate(10)
        )
        let finalMessage = ThreadMessage(threadID: otherThreadID, role: .assistant, content: "wrong history", timestamp: fixedDate(11))

        do {
            _ = try await repository.completeTurn(
                turnID: admission.turn.identity.turnID,
                outcome: .completed,
                finalMessage: finalMessage,
                terminalHandle: nil,
                now: fixedDate(12)
            )
            Issue.record("thread.completion.wrong-thread.must-fail")
            return
        } catch let error as ThreadRuntimeRepositoryError {
            try #require(
                error == .finalMessageThreadMismatch(
                    messageID: finalMessage.id,
                    expectedThreadID: threadID,
                    actualThreadID: otherThreadID
                ),
                "thread.completion.wrong-thread.error"
            )
        }

        let persistedTurn = try #require(try await repository.fetchTurn(id: admission.turn.identity.turnID), "thread.completion.wrong-thread.turn")
        try #require(persistedTurn.outcome == nil, "thread.completion.wrong-thread.no-outcome")
        try #require(try await repository.fetchMessages(for: threadID).isEmpty, "thread.completion.wrong-thread.no-target-message")
        try #require(try await repository.fetchMessages(for: otherThreadID).isEmpty, "thread.completion.wrong-thread.no-source-message")
        try #require(try await repository.fetchActiveTurn(for: threadID)?.identity.turnID == admission.turn.identity.turnID, "thread.completion.wrong-thread.remains-active")
    }

    private static func fixedDate(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
