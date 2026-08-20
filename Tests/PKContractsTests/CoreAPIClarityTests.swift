import Foundation
import Logging
import Testing
@testable import PKContracts
@testable import PKUtilities

@Suite("Core API clarity compatibility")
struct CoreAPIClarityTests {
    @Test("Default-heavy shared initializers resolve to the canonical overload")
    func defaultHeavySharedInitializersResolveToCanonicalOverload() {
        let message = Message(content: "hello", role: .user)
        let workspace = WorkspaceReference(
            uri: .threadWorkspace(UUID()),
            location: .runtime
        )

        #expect(message.toolCallID == nil)
        #expect(message.parentID == nil)
        #expect(workspace.originID == nil)
    }

    @Test("Message canonical identifiers preserve legacy JSON keys")
    func messageCanonicalIdentifiersPreserveLegacyJSONKeys() throws {
        let parentID = UUID()
        let message = Message(
            content: "result",
            role: .tool,
            toolCallID: "call-1",
            parentID: parentID
        )

        #expect(message.toolCallID == "call-1")
        #expect(message.parentID == parentID)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
                as? [String: Any]
        )
        #expect(object["toolCallId"] as? String == "call-1")
        #expect(object["parentId"] as? String == parentID.uuidString)
        #expect(object["toolCallID"] == nil)
        #expect(object["parentID"] == nil)
    }

    @Test("Canonical shared-model identifiers preserve all legacy JSON keys")
    func canonicalSharedModelIdentifiersPreserveLegacyJSONKeys() throws {
        let timelineID = UUID()
        let agentInstanceID = UUID()
        let workspaceID = UUID()

        let identity = TurnIdentity(sendID: UUID(), roundTrip: 2)
        let submission = ToolOutputSubmission(toolCallID: "call-2", output: "done")
        let agent = AgentInstance(
            name: "Agent",
            description: "Test",
            primaryWorkspaceID: workspaceID,
            privateThreadID: timelineID
        )
        let workspace = WorkspaceReference(
            uri: .threadWorkspace(timelineID),
            location: .runtime,
            originID: agentInstanceID
        )
        let snapshot = TurnSnapshot(
            threadID: timelineID,
            agentInstanceID: agentInstanceID,
            modelName: "test",
            turnCount: 1,
            maxTurns: 2,
            availableToolIDs: ["tool-1"]
        )
        let diagnostic = TurnDiagnostic(
            dependency: .agent,
            operation: "fetch",
            entityID: agentInstanceID.uuidString,
            errorIdentity: nil,
            message: "missing"
        )
        let compressionMetric = StructuredCompressionNodeMetric(
            nodeID: "node-1",
            path: ["root"],
            action: "keep",
            beforeTokens: 3,
            afterTokens: 3,
            cacheHit: false
        )

        let values: [(data: Data, requiredKeys: Set<String>, forbiddenKeys: Set<String>)] = [
            (try JSONEncoder().encode(identity), ["sendId", "roundTrip"], ["sendID"]),
            (try JSONEncoder().encode(submission), ["toolCallId", "output"], ["toolCallID"]),
            (try JSONEncoder().encode(agent), ["primaryWorkspaceId", "privateTimelineId"], ["primaryWorkspaceID", "privateTimelineID"]),
            (try JSONEncoder().encode(workspace), ["originId"], ["originID"]),
            (try JSONEncoder().encode(snapshot), ["timelineId", "agentInstanceId", "availableToolIds"], ["timelineID", "agentInstanceID", "availableToolIDs"]),
            (try JSONEncoder().encode(diagnostic), ["entityId"], ["entityID"]),
            (try JSONEncoder().encode(compressionMetric), ["nodeId"], ["nodeID"]),
        ]

        for value in values {
            let object = try #require(JSONSerialization.jsonObject(with: value.data) as? [String: Any])
            #expect(value.requiredKeys.isSubset(of: Set(object.keys)))
            #expect(value.forbiddenKeys.isDisjoint(with: Set(object.keys)))
        }
    }
}
