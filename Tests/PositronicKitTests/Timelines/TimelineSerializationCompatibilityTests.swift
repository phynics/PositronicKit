import Foundation
import Testing
@testable import PositronicKit
import PKContracts

/// Golden payloads from the pre-Timeline API. These fixtures intentionally retain their wire keys
/// while the decoded Swift values use the renamed Timeline family.
@Suite("Timeline serialization compatibility", .tags(.unit))
struct TimelineSerializationCompatibilityTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func fixtureDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test("Timeline metadata decodes and re-encodes the persisted shape")
    func timelineRecordRoundTrip() throws {
        let payload = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Research","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","isArchived":false,"workingDirectory":"/tmp/research","attachedAgentId":"00000000-0000-0000-0000-000000000002","isPrivate":false}"#
        let record = try decoder.decode(TimelineRecord.self, from: Data(payload.utf8))

        #expect(record.id.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(record.title == "Research")
        #expect(record.createdAt == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(record.updatedAt == fixtureDate("2026-01-02T00:00:00Z"))
        #expect(record.isArchived == false)
        #expect(record.workingDirectory == "/tmp/research")
        #expect(record.attachedAgentID?.uuidString == "00000000-0000-0000-0000-000000000002")
        #expect(record.isPrivate == false)
        try assertWireKeys(of: record, contains: ["attachedAgentId"], excludes: ["timelineId", "timelineID"])
    }

    @Test("renamed timeline identifiers preserve all established encoded spellings")
    func renamedIdentifiersRoundTrip() throws {
        let messagePayload = #"{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000011","role":"user","content":"hello","timestamp":"2026-01-01T00:00:00Z","remoteDepth":0,"toolCalls":"[]"}"#
        let message = try decoder.decode(TimelineMessage.self, from: Data(messagePayload.utf8))
        #expect(message.id.uuidString == "00000000-0000-0000-0000-000000000010")
        #expect(message.timelineID.uuidString == "00000000-0000-0000-0000-000000000011")
        #expect(message.role == "user")
        #expect(message.content == "hello")
        #expect(message.messageContent.text == "hello")
        #expect(message.timestamp == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(message.parentID == nil)
        #expect(message.reasoning == nil)
        #expect(message.toolCalls == "[]")
        #expect(message.toolCallID == nil)
        #expect(message.agentID == nil)
        #expect(message.executionKind == nil)
        #expect(message.remoteDepth == 0)
        #expect(message.snapshotData == nil)
        #expect(message.status == nil)
        try assertWireKeys(
            of: message,
            contains: ["threadId"],
            excludes: ["timelineId", "timelineID", "privateTimelineId"])

        let snapshotPayload = #"{"timestamp":"2026-01-01T00:00:00Z","threadId":"00000000-0000-0000-0000-000000000011","agentId":"00000000-0000-0000-0000-000000000012","modelName":"fixture","modelRoundIndex":0,"maxModelRounds":1,"availableToolIds":[],"fullResponse":"","fullThinking":"","toolCalls":[],"toolResults":[],"turnDuration":0}"#
        let snapshot = try decoder.decode(TurnSnapshot.self, from: Data(snapshotPayload.utf8))
        #expect(snapshot.timestamp == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(snapshot.timelineID.uuidString == "00000000-0000-0000-0000-000000000011")
        #expect(snapshot.agentID?.uuidString == "00000000-0000-0000-0000-000000000012")
        #expect(snapshot.modelName == "fixture")
        #expect(snapshot.modelRoundIndex == 0)
        #expect(snapshot.maxModelRounds == 1)
        #expect(snapshot.systemInstructions == nil)
        #expect(snapshot.contextSnapshot == nil)
        #expect(snapshot.availableToolIDs == [])
        #expect(snapshot.fullResponse == "")
        #expect(snapshot.fullThinking == "")
        #expect(snapshot.audioOutput == nil)
        #expect(snapshot.toolCalls == [])
        #expect(snapshot.toolResults == [])
        #expect(snapshot.turnDuration == 0)
        #expect(snapshot.tokensPerSecond == nil)
        #expect(snapshot.usage == nil)
        try assertWireKeys(
            of: snapshot,
            contains: ["threadId", "availableToolIds"],
            excludes: ["timelineId", "timelineID", "privateTimelineId"])

        let agentPayload = #"{"id":"00000000-0000-0000-0000-000000000012","name":"Agent","description":"Fixture","lifecycle":"active","primaryWorkspaceId":null,"privateThreadId":"00000000-0000-0000-0000-000000000011","lastActiveAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","metadata":{}}"#
        let agent = try decoder.decode(Agent.self, from: Data(agentPayload.utf8))
        #expect(agent.id.uuidString == "00000000-0000-0000-0000-000000000012")
        #expect(agent.name == "Agent")
        #expect(agent.description == "Fixture")
        #expect(agent.lifecycle == .active)
        #expect(agent.primaryWorkspaceID == nil)
        #expect(agent.privateTimelineID.uuidString == "00000000-0000-0000-0000-000000000011")
        #expect(agent.lastActiveAt == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(agent.createdAt == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(agent.updatedAt == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(agent.metadata.isEmpty)
        try assertWireKeys(
            of: agent,
            contains: ["privateThreadId"],
            excludes: ["timelineId", "timelineID", "privateTimelineId"])

        let bindingPayload = #"{"workspaceID":"00000000-0000-0000-0000-000000000020","threadID":"00000000-0000-0000-0000-000000000011","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
        let binding = try decoder.decode(WorkspaceBinding.self, from: Data(bindingPayload.utf8))
        #expect(binding.workspaceID.uuidString == "00000000-0000-0000-0000-000000000020")
        #expect(binding.timelineID.uuidString == "00000000-0000-0000-0000-000000000011")
        #expect(binding.createdAt == fixtureDate("2026-01-01T00:00:00Z"))
        #expect(binding.updatedAt == fixtureDate("2026-01-01T00:00:00Z"))
        try assertWireKeys(
            of: binding,
            contains: ["threadID"],
            excludes: ["timelineId", "timelineID", "privateTimelineId"])
    }

    @Test("a legacy tool result row with errorMessage still decodes")
    func legacyToolResultDecodesAfterErrorMessageRemoval() throws {
        let payload = #"{"id":"00000000-0000-0000-0000-000000000030","turnID":"00000000-0000-0000-0000-000000000031","threadID":"00000000-0000-0000-0000-000000000032","toolCallID":"call-1","output":"Error: boom","isSuccessful":false,"errorMessage":"boom","workspaceID":null,"workspaceRouting":null,"createdAt":"2026-01-01T00:00:00Z"}"#
        let result = try decoder.decode(RuntimeToolResult.self, from: Data(payload.utf8))

        #expect(result.id.uuidString == "00000000-0000-0000-0000-000000000030")
        #expect(result.turnID.uuidString == "00000000-0000-0000-0000-000000000031")
        #expect(result.timelineID.uuidString == "00000000-0000-0000-0000-000000000032")
        #expect(result.toolCallID == "call-1")
        #expect(result.output == "Error: boom")
        #expect(result.isSuccessful == false)
        #expect(result.workspaceID == nil)
        #expect(result.createdAt == fixtureDate("2026-01-01T00:00:00Z"))

        // Re-encoding the current shape drops the retired key and keeps the wire key.
        let reencoded = try encoder.encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(object["errorMessage"] == nil)
        #expect(object["threadID"] as? String == "00000000-0000-0000-0000-000000000032")
    }

    private func assertWireKeys<T: Encodable>(
        of value: T,
        contains required: Set<String>,
        excludes forbidden: Set<String>
    ) throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any]
        )
        let keys = Set(object.keys)
        #expect(required.isSubset(of: keys))
        #expect(forbidden.isDisjoint(with: keys))
    }
}
