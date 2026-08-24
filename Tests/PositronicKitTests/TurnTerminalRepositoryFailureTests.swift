import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Testing

@Suite("Turn terminal repository failure")
struct TurnTerminalRepositoryFailureTests {
    @Test("terminal repository failure suppresses terminal delivery")
    func terminalFailureDoesNotExposeCompletion() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "must not be delivered"
        let repository = FailingTerminalRepository()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(runtimeRepository: repository)
        ))
        let thread = try await kit.threads.create(title: "Terminal failure")

        let stream = try await kit.run(TurnRequest(
            threadID: thread.id,
            message: "finish this turn"
        ))

        var events: [TurnEvent] = []
        await #expect(throws: Error.self) {
            for try await event in stream {
                events.append(event)
            }
        }

        #expect(events.filter(\.isTerminal).isEmpty)
        let record = try #require(try await repository.fetchActiveTurn(for: thread.id))
        #expect(record.outcome == nil)
    }
}

private enum TerminalRepositoryTestError: Error, Sendable {
    case unavailable
}

actor FailingTerminalRepository: ThreadRuntimeRepository {
    private let base = InMemoryThreadRuntimeRepository()

    nonisolated var isDurable: Bool { false }

    func saveThread(_ thread: Thread) async throws {
        try await base.saveThread(thread)
    }

    func fetchThread(id: UUID) async throws -> Thread? {
        try await base.fetchThread(id: id)
    }

    func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        try await base.fetchAllThreads(includeArchived: includeArchived)
    }

    func deleteThread(id: UUID) async throws {
        try await base.deleteThread(id: id)
    }

    func pruneThreads(olderThan timeInterval: TimeInterval, excluding excludedThreadIDs: [UUID], dryRun: Bool) async throws -> Int {
        try await base.pruneThreads(olderThan: timeInterval, excluding: excludedThreadIDs, dryRun: dryRun)
    }

    func saveMessage(_ message: ThreadMessage) async throws {
        try await base.saveMessage(message)
    }

    func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
        try await base.fetchMessages(for: threadID)
    }

    func deleteMessages(for threadID: UUID) async throws {
        try await base.deleteMessages(for: threadID)
    }

    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await base.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        try await base.fetchSnapshots(for: threadID)
    }

    func admitTurn(
        threadID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: ThreadMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        try await base.admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
    }

    func admitRetry(
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
        try await base.admitRetry(
            threadID: threadID,
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
    }

    func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try await base.fetchTurn(id: id)
    }

    func fetchActiveTurn(for threadID: UUID) async throws -> TurnRecord? {
        try await base.fetchActiveTurn(for: threadID)
    }

    func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        try await base.appendNotice(turnID: turnID, notice: notice)
    }

    func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        try await base.appendCorrelation(turnID: turnID, correlation: correlation, now: now)
    }

    func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try await base.fetchNotices(turnID: turnID)
    }

    func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try await base.fetchCorrelations(turnID: turnID)
    }

    func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        try await base.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now)
    }

    func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date) async throws {
        try await base.recordProviderRequest(turnID: turnID, modelRoundIndex: modelRoundIndex, correlation: correlation, now: now)
    }

    func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        try await base.recordToolIntent(intent)
    }

    func recordToolResult(_ result: RuntimeToolResult) async throws {
        try await base.recordToolResult(result)
    }

    func recordToolResult(_ result: RuntimeToolResult, message: ThreadMessage) async throws {
        try await base.recordToolResult(result, message: message)
    }

    func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] {
        try await base.fetchToolIntents(turnID: turnID)
    }

    func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] {
        try await base.fetchToolResults(turnID: turnID)
    }

    func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: ThreadMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord {
        throw TerminalRepositoryTestError.unavailable
    }

    func failTurn(turnID: UUID, message: String, now: Date) async throws -> TurnRecord {
        try await base.failTurn(turnID: turnID, message: message, now: now)
    }

    func cancelTurn(turnID: UUID, reason: String?, now: Date) async throws -> TurnRecord {
        try await base.cancelTurn(turnID: turnID, reason: reason, now: now)
    }

    func interruptTurn(turnID: UUID, reason: String, force: Bool, now: Date) async throws -> TurnRecord {
        try await base.interruptTurn(turnID: turnID, reason: reason, force: force, now: now)
    }

    func recover(threadID: UUID, now: Date) async throws -> TurnRecoveryResult {
        try await base.recover(threadID: threadID, now: now)
    }

    func forceClear(threadID: UUID, confirmation: ForceClearConfirmation, now: Date) async throws -> TurnRecord? {
        try await base.forceClear(threadID: threadID, confirmation: confirmation, now: now)
    }

    func saveSummary(_ summary: ThreadSummary) async throws {
        try await base.saveSummary(summary)
    }

    func fetchSummaries(for threadID: UUID) async throws -> [ThreadSummary] {
        try await base.fetchSummaries(for: threadID)
    }
}
