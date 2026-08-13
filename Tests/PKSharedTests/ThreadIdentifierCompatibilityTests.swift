import Foundation
import PKShared
import struct PositronicKit.Thread
import PositronicKit
import Testing

@Suite("Thread identifiers")
struct ThreadIdentifierCompatibilityTests {
    private typealias ThreadModel = Thread

    @Test("the timeline typealias preserves value compatibility")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func legacyTimelineTypealias() {
        let thread = ThreadModel(title: "Legacy")
        let timeline: Timeline = thread

        #expect(timeline.id == thread.id)
        #expect(timeline.title == thread.title)
    }

    @Test("canonical Codable keeps historical persistence keys")
    func canonicalCodableKeepsHistoricalKeys() throws {
        let thread = ThreadModel(
            attachedWorkspaceIDs: [UUID()],
            attachedAgentInstanceID: UUID()
        )
        let data = try JSONEncoder().encode(thread)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["attachedWorkspaceIds"] != nil)
        #expect(object["attachedAgentInstanceId"] != nil)
        #expect(object["attachedWorkspaceIDs"] == nil)
    }

    @Test("canonical identifiers preserve legacy persistence keys")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func canonicalIdentifiersPreserveLegacyPersistenceKeys() throws {
        let workspaceID = UUID()
        let thread = ThreadModel(title: "Stable", attachedWorkspaceIDs: [workspaceID])
        let message = ConversationMessage(threadID: thread.id, role: .user, content: "Hi")
        let snapshot = TurnSnapshot(
            threadID: thread.id,
            modelName: "test-model",
            turnCount: 0,
            maxTurns: 1
        )
        let agent = AgentInstance(
            name: "Agent",
            description: "Test agent",
            privateThreadID: thread.id
        )
        let workspace = WorkspaceReference(
            uri: .threadWorkspace(thread.id),
            location: .runtimeTimeline
        )

        #expect(message.threadID == thread.id)
        #expect(snapshot.threadID == thread.id)
        #expect(WorkspaceURI.threadWorkspace(thread.id).rawValue ==
                WorkspaceURI.timelineWorkspace(thread.id).rawValue)

        let messageObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        let snapshotObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        let agentObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any]
        )
        let workspaceObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any]
        )

        #expect(messageObject["timelineId"] != nil)
        #expect(messageObject["threadID"] == nil)
        #expect(snapshotObject["timelineId"] != nil)
        #expect(snapshotObject["threadID"] == nil)
        #expect(agentObject["privateTimelineId"] != nil)
        #expect(agentObject["privateThreadID"] == nil)
        #expect(workspaceObject["location"] as? String == "runtimeTimeline")
    }

    @Test("canonical and legacy workspace URI spellings share the durable value")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func workspaceURISpellingsShareDurableValue() {
        let id = UUID()

        #expect(WorkspaceURI.threadWorkspace(id).rawValue ==
                WorkspaceURI.timelineWorkspace(id).rawValue)
    }

    @Test("canonical persistence stores threads through the new requirements")
    func canonicalPersistenceStoresThreads() async throws {
        let store = InMemoryThreadPersistence()
        let thread = ThreadModel(title: "Persisted")

        try await store.saveThread(thread)

        #expect(try await store.fetchThread(id: thread.id)?.title == "Persisted")
        #expect(try await store.fetchAllThreads(includeArchived: false).count == 1)
    }
}
