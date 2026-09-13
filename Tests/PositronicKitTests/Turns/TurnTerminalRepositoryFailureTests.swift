import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Turn terminal repository failure", .tags(.integration))
struct TurnTerminalRepositoryFailureTests {
    @Test("terminal repository failure is exposed as a distinct terminal event")
    func terminalFailureExposesDurabilityFailure() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "must not be delivered"
        let repository = FailingTerminalRepository()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: repository)
        ))
        let timeline = try await kit.timelines.create(title: "Terminal failure")

        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "finish this turn",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let events = await turn.events().collect()

        #expect(events.filter(\.isTerminal).count == 1)
        #expect(events.contains { event in
            if case .error(.durabilityFailure) = event { return true }
            return false
        })
        let record = try #require(try await repository.fetchActiveTurn(for: timeline.id))
        #expect(record.outcome == nil)
    }
}

private enum TerminalRepositoryTestError: Error, Sendable {
    case unavailable
}

actor FailingTerminalRepository: TimelineRuntimeRepository {
    private let base = InMemoryTimelineRuntimeRepository()

    nonisolated var isDurable: Bool { false }

    func saveTimeline(_ timeline: TimelineRecord) async throws {
        try await base.saveTimeline(timeline)
    }

    func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        try await base.fetchTimeline(id: id)
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        try await base.fetchAllTimelines(includeArchived: includeArchived)
    }

    func deleteTimeline(id: UUID) async throws {
        try await base.deleteTimeline(id: id)
    }

    func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIDs: [UUID], dryRun: Bool) async throws -> Int {
        try await base.pruneTimelines(olderThan: timeInterval, excluding: excludedTimelineIDs, dryRun: dryRun)
    }

    func saveMessage(_ message: TimelineMessage) async throws {
        try await base.saveMessage(message)
    }

    func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        try await base.fetchMessages(for: timelineID)
    }

    func deleteMessages(for timelineID: UUID) async throws {
        try await base.deleteMessages(for: timelineID)
    }

    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await base.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        try await base.fetchSnapshots(for: timelineID)
    }

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
        try await base.admitTurn(
            timelineID: timelineID,
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
        try await base.admitRetry(
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
    }

    func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try await base.fetchTurn(id: id)
    }

    func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        try await base.fetchActiveTurn(for: timelineID)
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

    func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
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
        finalMessage: TimelineMessage?,
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

    func recover(timelineID: UUID, now: Date) async throws -> TurnRecoveryResult {
        try await base.recover(timelineID: timelineID, now: now)
    }

    func forceClear(timelineID: UUID, confirmation: ForceClearConfirmation, now: Date) async throws -> TurnRecord? {
        try await base.forceClear(timelineID: timelineID, confirmation: confirmation, now: now)
    }

    func saveSummary(_ summary: TimelineSummary) async throws {
        try await base.saveSummary(summary)
    }

    func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] {
        try await base.fetchSummaries(for: timelineID)
    }
}
