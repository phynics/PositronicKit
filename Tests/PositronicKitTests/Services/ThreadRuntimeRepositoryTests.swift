import Foundation
import PositronicKit
import XCTest

final class ThreadRuntimeRepositoryTests: XCTestCase {
    func testAdmissionSerializesThreadAndIsIdempotentByFingerprint() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let requestID = UUID()

        let first = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:a"
        )
        XCTAssertEqual(first.disposition, .admitted)

        let joined = try await repository.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: "message:a"
        )
        XCTAssertEqual(joined.disposition, .joined)
        XCTAssertEqual(joined.turn.identity.turnID, first.turn.identity.turnID)

        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: UUID(),
                callerIntentFingerprint: "message:b"
            )
            XCTFail("A second active request must be rejected")
        } catch let error as ThreadRuntimeRepositoryError {
            guard case let .threadBusy(id, activeTurnID) = error else {
                return XCTFail("Unexpected error: \(String(describing: error))")
            }
            XCTAssertEqual(id, threadID)
            XCTAssertEqual(activeTurnID, first.turn.identity.turnID)
        }

        do {
            _ = try await repository.admitTurn(
                threadID: threadID,
                requestID: requestID,
                callerIntentFingerprint: "message:changed"
            )
            XCTFail("Changing the fingerprint must be a conflict")
        } catch let error as ThreadRuntimeRepositoryError {
            XCTAssertEqual(error, .idempotencyConflict(requestID: requestID))
        }
    }

    func testToolIntentAndResultAreOrderingBarriersForNextRound() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "tool"
        )
        let turnID = admission.turn.identity.turnID
        let intent = RuntimeToolIntent(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0
        )
        try await repository.recordToolIntent(intent)

        do {
            try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1)
            XCTFail("A next model round cannot start before the tool result")
        } catch let error as ThreadRuntimeRepositoryError {
            XCTAssertEqual(error, .toolIntentRequired(turnID: turnID, toolCallID: "call-1"))
        }

        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            output: "ok"
        ))
        try await repository.beginModelRound(turnID: turnID, modelRoundIndex: 1)
        let intents = try await repository.fetchToolIntents(turnID: turnID)
        let results = try await repository.fetchToolResults(turnID: turnID)
        XCTAssertEqual(intents, [intent])
        XCTAssertEqual(results.count, 1)
    }

    func testToolResultAndMessageAreCommittedTogether() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "atomic"
        )
        let turnID = admission.turn.identity.turnID
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0
        ))
        let message = ThreadMessage(threadID: threadID, role: .tool, content: "ok", toolCallID: "call-1")
        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID,
            threadID: threadID,
            toolCallID: "call-1",
            output: "ok"
        ), message: message)

        let persistedMessages = try await repository.fetchMessages(for: threadID)
        let persistedResults = try await repository.fetchToolResults(turnID: turnID)
        XCTAssertEqual(persistedMessages.map(\.id), [message.id])
        XCTAssertEqual(persistedMessages.first?.content, message.content)
        XCTAssertEqual(persistedResults.count, 1)
    }

    func testHistoryIsAppendOnlyAndSummaryRequiresDurableSources() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let messageID = UUID()
        let message = ThreadMessage(id: messageID, threadID: threadID, role: .user, content: "hello")
        try await repository.saveMessage(message)
        try await repository.saveMessage(message) // exact retry is a no-op

        do {
            try await repository.saveMessage(ThreadMessage(id: messageID, threadID: threadID, role: .user, content: "changed"))
            XCTFail("History must not be overwritten")
        } catch let error as ThreadRuntimeRepositoryError {
            XCTAssertEqual(error, .appendOnlyViolation(messageID: messageID))
        }

        let summary = ThreadSummary(threadID: threadID, sourceMessageIDs: [messageID], text: "hello")
        try await repository.saveSummary(summary)
        let summaries = try await repository.fetchSummaries(for: threadID)
        XCTAssertEqual(summaries, [summary])

        try await repository.deleteThread(id: threadID)
        let retainedMessages = try await repository.fetchMessages(for: threadID)
        let retainedSummaries = try await repository.fetchSummaries(for: threadID)
        XCTAssertEqual(retainedMessages.map(\.id), [message.id])
        XCTAssertEqual(retainedMessages.first?.content, message.content)
        XCTAssertEqual(retainedSummaries, [summary])
    }

    func testStaleRecoveryAndForceClearPreserveDurableRecords() async throws {
        let repository = InMemoryThreadRuntimeRepository(staleAfter: 1)
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        let admission = try await repository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "recover",
            now: Date(timeIntervalSince1970: 10)
        )
        let intent = RuntimeToolIntent(
            turnID: admission.turn.identity.turnID,
            threadID: threadID,
            toolCallID: "call-1",
            name: "lookup",
            arguments: "{}",
            modelRoundIndex: 0,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        try await repository.recordToolIntent(intent)

        let recovery = try await repository.recover(threadID: threadID, now: Date(timeIntervalSince1970: 20))
        guard case let .recoveryRequired(record) = recovery else {
            return XCTFail("Expected stale Turn recovery")
        }
        XCTAssertTrue(record.recoveryRequired)
        let intents = try await repository.fetchToolIntents(turnID: record.identity.turnID)
        let activeTurn = try await repository.fetchActiveTurn(for: threadID)
        XCTAssertEqual(intents, [intent])
        XCTAssertNil(activeTurn)

        guard case let .recoveryRequired(secondRecovery) = try await repository.recover(
            threadID: threadID,
            now: Date(timeIntervalSince1970: 21)
        ) else {
            return XCTFail("Recovery-required status must remain visible after stale interruption")
        }
        XCTAssertEqual(secondRecovery.identity.turnID, record.identity.turnID)
    }

    func testForceClearRequiresExplicitConfirmation() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID))
        _ = try await repository.admitTurn(threadID: threadID, requestID: UUID(), callerIntentFingerprint: "admin")

        do {
            _ = try await repository.forceClear(
                threadID: threadID,
                confirmation: ForceClearConfirmation(phrase: "yes"),
                now: Date()
            )
            XCTFail("Force clear must require its explicit phrase")
        } catch let error as ThreadRuntimeRepositoryError {
            XCTAssertEqual(error, .confirmationRequired)
        }

        let cleared = try await repository.forceClear(
            threadID: threadID,
            confirmation: ForceClearConfirmation(phrase: ForceClearConfirmation.requiredPhrase),
            now: Date()
        )
        XCTAssertNotNil(cleared)
        let activeTurn = try await repository.fetchActiveTurn(for: threadID)
        let persistedTurn = try await repository.fetchTurn(id: cleared!.identity.turnID)
        XCTAssertNil(activeTurn)
        XCTAssertNotNil(persistedTurn)
        let forceClearRecovery = try await repository.recover(threadID: threadID, now: Date())
        guard case .recoveryRequired = forceClearRecovery else {
            return XCTFail("Force clear must preserve the recovery-required marker")
        }
    }
}
