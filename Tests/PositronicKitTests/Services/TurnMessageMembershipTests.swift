import Foundation
import PKContracts
import PositronicKit
import Testing

@Suite("Turn message membership")
struct TurnMessageMembershipTests {
    @Test("Membership follows repository writes, excluding interleaved messages")
    func orderedMembership() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "question")
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: input.id,
            callerIntentFingerprint: "question",
            inputMessage: input
        )
        let turnID = admission.turn.identity.turnID
        let assistant = TimelineMessage(timelineID: timelineID, role: .assistant, content: "calling tool")
        try await repository.recordTurnMessage(assistant, turnID: turnID)
        let unrelated = TimelineMessage(timelineID: timelineID, role: .user, content: "other writer")
        try await repository.saveMessage(unrelated)
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: turnID, timelineID: timelineID, toolCallID: "call-1", name: "lookup",
            arguments: "{}", modelRoundIndex: 0
        ))
        let resultMessage = TimelineMessage(timelineID: timelineID, role: .tool, content: "answer", toolCallID: "call-1")
        try await repository.recordToolResult(RuntimeToolResult(
            turnID: turnID, timelineID: timelineID, toolCallID: "call-1", output: "answer"
        ), message: resultMessage)
        let final = TimelineMessage(timelineID: timelineID, role: .assistant, content: "done")
        _ = try await repository.completeTurn(turnID: turnID, finalMessage: final)

        let members = try #require(try await repository.fetchTurnMessages(turnID: turnID))
        #expect(members.map(\.id) == [input.id, assistant.id, resultMessage.id, final.id])
        #expect(try await repository.fetchMessages(for: timelineID).contains(where: { $0.id == unrelated.id }))
        #expect(try await repository.fetchTurn(id: turnID)?.terminalMessageID == final.id)
    }

    @Test("An unrelated existing message cannot become a Turn member")
    func rejectsForeignMessage() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let turn = try await repository.admitTurn(
            timelineID: timelineID, requestID: UUID(), callerIntentFingerprint: "no input"
        )
        let foreign = TimelineMessage(timelineID: timelineID, role: .assistant, content: "other writer")
        try await repository.saveMessage(foreign)
        await #expect(throws: TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: foreign.id)) {
            try await repository.recordTurnMessage(foreign, turnID: turn.turn.identity.turnID)
        }
        #expect(try await repository.fetchTurnMessages(turnID: turn.turn.identity.turnID)?.isEmpty == true)
    }

    @Test("Admission cannot claim an unrelated existing input message")
    func rejectsForeignInput() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let foreign = TimelineMessage(timelineID: timelineID, role: .user, content: "existing")
        try await repository.saveMessage(foreign)

        await #expect(throws: TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: foreign.id)) {
            _ = try await repository.admitTurn(
                timelineID: timelineID,
                requestID: UUID(),
                callerIntentFingerprint: "different request",
                inputMessage: foreign
            )
        }
    }

    @Test("A foreign existing message cannot be committed as the terminal message")
    func rejectsForeignTerminalMessage() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let turn = try await repository.admitTurn(
            timelineID: timelineID, requestID: UUID(), callerIntentFingerprint: "terminal"
        )
        let foreign = TimelineMessage(timelineID: timelineID, role: .assistant, content: "another writer")
        try await repository.saveMessage(foreign)

        await #expect(throws: TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: foreign.id)) {
            _ = try await repository.completeTurn(turnID: turn.turn.identity.turnID, finalMessage: foreign)
        }
        #expect(try await repository.fetchTurn(id: turn.turn.identity.turnID)?.isTerminal == false)
        #expect(try await repository.fetchTurnMessages(turnID: turn.turn.identity.turnID)?.isEmpty == true)
    }

    @Test("Failed and retried Turns keep distinct membership, including a reused input")
    func retryMembership() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "retry me")
        let first = try await repository.admitTurn(
            timelineID: timelineID, requestID: input.id, callerIntentFingerprint: "retry me", inputMessage: input
        )
        let abandoned = TimelineMessage(timelineID: timelineID, role: .assistant, content: "partial")
        try await repository.recordTurnMessage(abandoned, turnID: first.turn.identity.turnID)
        _ = try await repository.failTurn(turnID: first.turn.identity.turnID, message: "provider failed")

        let retry = try await repository.admitRetry(
            timelineID: timelineID, previousTurnID: first.turn.identity.turnID,
            requestID: input.id, callerIntentFingerprint: "retry me", inputMessage: input,
            executionKind: .direct, capturedAgentID: nil, turnID: UUID(), attempt: 2, now: Date()
        )
        let completed = TimelineMessage(timelineID: timelineID, role: .assistant, content: "success")
        _ = try await repository.completeTurn(turnID: retry.turn.identity.turnID, finalMessage: completed)

        #expect(try await repository.fetchTurnMessages(turnID: first.turn.identity.turnID)?.map(\.id) == [input.id, abandoned.id])
        #expect(try await repository.fetchTurnMessages(turnID: retry.turn.identity.turnID)?.map(\.id) == [input.id, completed.id])
        #expect(try await repository.fetchMessages(for: timelineID).count == 3)
    }

    @Test("Cancelled Turns retain only messages already written for that Turn")
    func cancelledMembership() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID))
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "cancel me")
        let turn = try await repository.admitTurn(
            timelineID: timelineID, requestID: input.id, callerIntentFingerprint: "cancel me", inputMessage: input
        )
        let partial = TimelineMessage(timelineID: timelineID, role: .assistant, content: "partial")
        try await repository.recordTurnMessage(partial, turnID: turn.turn.identity.turnID)
        _ = try await repository.cancelTurn(turnID: turn.turn.identity.turnID, reason: "host cancelled")

        #expect(try await repository.fetchTurnMessages(turnID: turn.turn.identity.turnID)?.map(\.id) == [input.id, partial.id])
    }

    @Test("Absent membership remains unknown after decoding an older record")
    func legacyCoding() throws {
        let turn = TurnRecord(
            identity: TurnIdentity(turnID: UUID(), requestID: UUID(), modelRoundIndex: 0),
            timelineID: UUID(), callerIntent: TurnCallerIntent(requestID: UUID(), fingerprint: "test"),
            memberMessageIDs: []
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(turn)
        #expect(try JSONDecoder().decode(TurnRecord.self, from: data).memberMessageIDs == [])

        let memberIDs = [UUID(), UUID()]
        let populated = TurnRecord(
            identity: turn.identity,
            timelineID: turn.timelineID,
            callerIntent: turn.callerIntent,
            memberMessageIDs: memberIDs
        )
        let populatedData = try encoder.encode(populated)
        #expect(try JSONDecoder().decode(TurnRecord.self, from: populatedData).memberMessageIDs == memberIDs)

        let json = try JSONSerialization.jsonObject(with: data)
        var legacy = try #require(json as? [String: Any])
        legacy.removeValue(forKey: "memberMessageIDs")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(TurnRecord.self, from: oldData).memberMessageIDs == nil)
    }
}
