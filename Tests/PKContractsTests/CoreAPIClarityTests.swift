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
        let threadID = UUID()
        let agentID = UUID()
        let workspaceID = UUID()

        let identity = TurnIdentity(turnID: UUID(), requestID: UUID(), modelRoundIndex: 2)
        let submission = ToolOutputSubmission(toolCallID: "call-2", output: "done")
        let agent = Agent(
            name: "Agent",
            description: "Test",
            primaryWorkspaceID: workspaceID,
            privateThreadID: threadID
        )
        let workspace = WorkspaceReference(
            uri: .threadWorkspace(threadID),
            location: .runtime,
            originID: agentID
        )
        let snapshot = TurnSnapshot(
            threadID: threadID,
            agentID: agentID,
            modelName: "test",
            modelRoundIndex: 1,
            maxModelRounds: 2,
            availableToolIDs: ["tool-1"]
        )
        let diagnostic = TurnDiagnostic(
            dependency: .agent,
            operation: "fetch",
            entityID: agentID.uuidString,
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
            (try JSONEncoder().encode(identity), ["turnId", "requestId", "modelRoundIndex"], ["turnID", "requestID"]),
            (try JSONEncoder().encode(submission), ["toolCallId", "output"], ["toolCallID"]),
            (try JSONEncoder().encode(agent), ["primaryWorkspaceId", "privateThreadId"], ["primaryWorkspaceID", "privateThreadID"]),
            (try JSONEncoder().encode(workspace), ["originId"], ["originID"]),
            (try JSONEncoder().encode(snapshot), ["threadId", "agentId", "availableToolIds"], ["threadID", "agentID", "availableToolIDs"]),
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
