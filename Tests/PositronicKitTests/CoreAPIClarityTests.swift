import Foundation
import PKShared
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("PositronicKit core API clarity")
struct CoreAPIClarityTests {
    private actor LegacyOnlyWorkspaceResolver: WorkspaceResolver {
        private var requests = 0

        var activeWorkspaceCount: Int { 0 }

        func getWorkspace(id: UUID) async throws -> (any Workspace)? {
            requests += 1
            return nil
        }

        func closeWorkspace(id: UUID) async {}
        func healthCheckAll() async -> [UUID: Bool] { [:] }
        func requestCount() -> Int { requests }
    }

    private actor LegacyOnlyAgentInstanceManager: AgentInstanceManagerProtocol {
        let agent: AgentInstance
        let timeline: Timeline
        private var instanceRequests = 0
        private var timelineRequests = 0
        private var attachRequests = 0
        private var detachRequests = 0

        init(agent: AgentInstance, timeline: Timeline) {
            self.agent = agent
            self.timeline = timeline
        }

        func createInstance(
            from template: AgentTemplate?,
            name: String,
            description: String
        ) async throws -> AgentInstance { agent }

        func attach(agentId: UUID, to timelineId: UUID) async throws { attachRequests += 1 }
        func detach(agentId: UUID, from timelineId: UUID) async throws { detachRequests += 1 }
        func getInstance(id: UUID) async throws -> AgentInstance? {
            instanceRequests += 1
            return agent.id == id ? agent : nil
        }
        func listInstances() async throws -> [AgentInstance] { [agent] }
        func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline] {
            timelineRequests += 1
            return [timeline]
        }
        func updateInstance(_ instance: AgentInstance) async throws {}
        func searchInstances(query: String) async throws -> [AgentInstance] { [agent] }
        func deleteInstance(id: UUID, force: Bool) async throws {}

        func requestCounts() -> (instances: Int, timelines: Int, attaches: Int, detaches: Int) {
            (instanceRequests, timelineRequests, attachRequests, detachRequests)
        }
    }

    private actor LegacyOnlyWorkspaceCatalog: WorkspaceCatalog {
        private var workspaceCreations = 0
        private var agentWorkspaceCreations = 0

        func createWorkspace(
            uri: WorkspaceURI,
            location: WorkspaceReference.WorkspaceLocation,
            originId: UUID?,
            rootPath: String?
        ) async throws -> WorkspaceReference {
            workspaceCreations += 1
            return WorkspaceReference(
                uri: uri,
                location: location,
                originID: originId,
                rootPath: rootPath
            )
        }

        func createAgentWorkspace(
            instanceId: UUID,
            template _: AgentTemplate?
        ) async throws -> WorkspaceReference {
            agentWorkspaceCreations += 1
            return WorkspaceReference(
                uri: .agentWorkspace(instanceId),
                location: .runtime
            )
        }

        func getWorkspace(id _: UUID, includeTools _: Bool) async throws -> WorkspaceReference? { nil }
        func listWorkspaces() async throws -> [WorkspaceReference] { [] }
        func deleteWorkspace(id _: UUID, deleteDirectory _: Bool) async throws {}
        func updateWorkspace(_: WorkspaceReference) async throws {}

        func creationCounts() -> (workspaces: Int, agentWorkspaces: Int) {
            (workspaceCreations, agentWorkspaceCreations)
        }
    }

    @Test("Canonical protocol queries forward once to legacy-only conformers")
    func canonicalProtocolQueriesForwardToLegacyOnlyConformers() async throws {
        let resolver: any WorkspaceResolver = LegacyOnlyWorkspaceResolver()
        let resolved = try await resolver.workspace(id: UUID())
        #expect(resolved == nil)
        let legacyResolver = try #require(resolver as? LegacyOnlyWorkspaceResolver)
        #expect(await legacyResolver.requestCount() == 1)

        let agent = AgentInstance(
            name: "Legacy",
            description: "Legacy-only protocol conformer",
            privateTimelineID: UUID()
        )
        let timeline = Timeline()
        let legacyManager = LegacyOnlyAgentInstanceManager(
            agent: agent,
            timeline: timeline
        )
        let manager: any AgentInstanceManagerProtocol = legacyManager

        #expect(try await manager.instance(id: agent.id) == agent)
        let timelines = try await manager.timelines(attachedTo: agent.id)
        try await manager.attach(agentID: agent.id, to: timeline.id)
        try await manager.detach(agentID: agent.id, from: timeline.id)
        #expect(timelines.map(\.id) == [timeline.id])
        let counts = await legacyManager.requestCounts()
        #expect(counts.instances == 1)
        #expect(counts.timelines == 1)
        #expect(counts.attaches == 1)
        #expect(counts.detaches == 1)

        let legacyCatalog = LegacyOnlyWorkspaceCatalog()
        let catalog: any WorkspaceCatalog = legacyCatalog
        let originID = UUID()
        let instanceID = UUID()
        _ = try await catalog.createWorkspace(
            uri: WorkspaceURI(host: "external", path: "/project"),
            location: .attached,
            originID: originID,
            rootPath: "/project"
        )
        _ = try await catalog.createAgentWorkspace(instanceID: instanceID, template: nil)
        let creationCounts = await legacyCatalog.creationCounts()
        #expect(creationCounts.workspaces == 1)
        #expect(creationCounts.agentWorkspaces == 1)
    }

    @Test("Default-heavy Timeline initializer resolves to the canonical overload")
    func defaultHeavyTimelineInitializerResolvesToCanonicalOverload() {
        let timeline = Timeline()

        #expect(timeline.attachedWorkspaceIDs.isEmpty)
        #expect(timeline.attachedAgentInstanceID == nil)
    }

    @Test("Chat requests expose canonical identifiers and preserve legacy initialization")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
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
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
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
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
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
