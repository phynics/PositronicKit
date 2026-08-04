import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("PositronicKit core API clarity")
struct CoreAPIClarityTests {
    @Test("Chat requests expose canonical identifiers and preserve legacy initialization")
    func chatRunRequestIdentifierCompatibility() {
        let timelineID = UUID()
        let sendID = UUID()
        let agentInstanceID = UUID()

        let canonical = ChatRunRequest(
            timelineID: timelineID,
            sendID: sendID,
            message: "hello",
            agentInstanceID: agentInstanceID
        )
        #expect(canonical.timelineID == timelineID)
        #expect(canonical.sendID == sendID)
        #expect(canonical.agentInstanceID == agentInstanceID)

        let legacy = ChatRunRequest(
            timelineId: timelineID,
            sendId: sendID,
            message: "hello",
            agentInstanceId: agentInstanceID
        )
        #expect(legacy.timelineID == timelineID)
        #expect(legacy.sendID == sendID)
        #expect(legacy.agentInstanceID == agentInstanceID)
    }

    @Test("Timeline canonical identifiers preserve legacy JSON keys")
    func timelineCanonicalIdentifiersPreserveLegacyJSONKeys() throws {
        let workspaceID = UUID()
        let agentInstanceID = UUID()
        let timeline = Timeline(
            attachedWorkspaceIDs: [workspaceID],
            attachedAgentInstanceID: agentInstanceID
        )

        #expect(timeline.attachedWorkspaceIDs == [workspaceID])
        #expect(timeline.attachedAgentInstanceID == agentInstanceID)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline))
                as? [String: Any]
        )
        #expect(object["attachedWorkspaceIds"] != nil)
        #expect(object["attachedAgentInstanceId"] as? String == agentInstanceID.uuidString)
        #expect(object["attachedWorkspaceIDs"] == nil)
        #expect(object["attachedAgentInstanceID"] == nil)
    }

    @Test("Timeline legacy initializer forwards to canonical identifiers")
    func timelineLegacyInitializerForwardsToCanonicalIdentifiers() {
        let workspaceID = UUID()
        let agentInstanceID = UUID()
        let timeline = Timeline(
            attachedWorkspaceIds: [workspaceID],
            attachedAgentInstanceId: agentInstanceID
        )

        #expect(timeline.attachedWorkspaceIDs == [workspaceID])
        #expect(timeline.attachedAgentInstanceID == agentInstanceID)
    }

    @Test("Conversation message canonical identifiers preserve legacy JSON keys")
    func conversationMessageCanonicalIdentifiersPreserveLegacyJSONKeys() throws {
        let timelineID = UUID()
        let parentID = UUID()
        let agentInstanceID = UUID()
        let message = ConversationMessage(
            timelineID: timelineID,
            role: .tool,
            content: "done",
            parentID: parentID,
            toolCallID: "call-3",
            agentInstanceID: agentInstanceID
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
                as? [String: Any]
        )
        #expect(Set(["timelineId", "parentId", "toolCallId", "agentInstanceId"])
            .isSubset(of: Set(object.keys)))
        #expect(Set(["timelineID", "parentID", "toolCallID", "agentInstanceID"])
            .isDisjoint(with: Set(object.keys)))
    }

    @Test("Canonical LLM client queries preserve legacy accessor results")
    func canonicalLLMClientQueriesPreserveLegacyResults() async {
        let service = LLMService(storage: MockConfigurationService())

        #expect(await service.client() == nil)
        #expect(await service.utilityClient() == nil)
        #expect(await service.fastClient() == nil)
        #expect(await service.getClient() == nil)
        #expect(await service.getUtilityClient() == nil)
        #expect(await service.getFastClient() == nil)
    }
}
