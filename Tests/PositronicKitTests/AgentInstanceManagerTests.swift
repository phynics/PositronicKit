import Foundation
import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

struct AgentInstanceManagerTests {
    private let mock = MockPersistenceService()

    @Test("Validation: Name too short")
    func nameTooShort() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        await #expect(throws: AgentInstanceError.self) {
            _ = try await manager.createInstance(name: "Ab", description: "Valid desc")
        }
    }

    @Test("Validation: Description empty")
    func descriptionEmpty() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        await #expect(throws: AgentInstanceError.self) {
            _ = try await manager.createInstance(name: "Valid Name", description: "  ")
        }
    }

    @Test("Robustness: Cannot attach to private timeline")
    func cannotAttachToPrivate() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let otherAgentId = UUID()
        let otherAgent = AgentInstance(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let privateTimeline = Timeline(id: UUID(), title: "Private", attachedAgentInstanceId: agentId, isPrivate: true)

        try await mock.saveAgentInstance(agent)
        try await mock.saveAgentInstance(otherAgent)
        try await mock.saveTimeline(privateTimeline)

        // Fails: attaching different agent to private timeline
        await #expect(throws: AgentInstanceError.self) {
            try await manager.attach(agentId: otherAgentId, to: privateTimeline.id)
        }

        // Succeeds: attaching owner (idempotent)
        try await manager.attach(agentId: agent.id, to: privateTimeline.id)
    }

    @Test("Robustness: Cannot detach agent from its own private timeline")
    func cannotDetachFromOwnPrivate() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let privateTimeline = Timeline(id: agent.privateTimelineId, title: "Private", attachedAgentInstanceId: agentId, isPrivate: true)

        try await mock.saveAgentInstance(agent)
        try await mock.saveTimeline(privateTimeline)

        await #expect(throws: AgentInstanceError.self) {
            try await manager.detach(agentId: agentId, from: privateTimeline.id)
        }
    }

    @Test("Creation: Agent is automatically attached to private timeline")
    func createInstanceAttachesAgent() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let instance = try await manager.createInstance(name: "New Agent", description: "Desc")

        let timeline = try await mock.fetchTimeline(id: instance.privateTimelineId)
        #expect(timeline?.attachedAgentInstanceId == instance.id)
        #expect(timeline?.isPrivate == true)
    }

    @Test("Search: Find by name or description")
    func searchInstances() async throws {
        let repo = AgentWorkspaceService(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agent1 = AgentInstance(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let agent2 = AgentInstance(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceId: UUID(), privateTimelineId: UUID())

        try await mock.saveAgentInstance(agent1)
        try await mock.saveAgentInstance(agent2)

        let resultsName = try await manager.searchInstances(query: "research")
        #expect(resultsName.count == 1)
        #expect(resultsName.first?.name == "Researcher")

        let resultsDesc = try await manager.searchInstances(query: "Swift")
        #expect(resultsDesc.count == 1)
        #expect(resultsDesc.first?.name == "Coder")

        let resultsEmpty = try await manager.searchInstances(query: "")
        #expect(resultsEmpty.count == 2)
    }

    @Test("Deletion: routes private-timeline deletion through TimelineManager when injected (PKR-3)")
    func deleteInstanceEvictsTimelineManagerCacheAndRegistry() async throws {
        // Use the same in-memory stores across the TimelineManager and the
        // AgentInstanceManager so the private timeline created by the agent
        // manager is visible to the timeline manager's store and cache.
        let timelineStore = InMemoryTimelinePersistence()
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let instanceStore = InMemoryAgentInstanceStore()
        let registry = TimelinePromptHistoryRegistry()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore,
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceRoot: workspaceRoot,
            promptHistoryRegistry: registry
        )

        let repo = AgentWorkspaceService(
            workspaceRoot: workspaceRoot,
            workspacePersistence: workspaceStore
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: instanceStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            ),
            timelineManager: timelineManager
        )

        let instance = try await manager.createInstance(name: "Eviction Target", description: "Desc")

        // Hydrate the private timeline into the TimelineManager cache and populate the registry.
        try await timelineManager.hydrateTimeline(id: instance.privateTimelineId)
        #expect(await timelineManager.getTimeline(id: instance.privateTimelineId) != nil)

        let history = await registry.history(for: instance.privateTimelineId)
        await history.recordAppend(messageCount: 4, estimatedTokens: 120)
        #expect(await history.appendedMessageCount == 4)

        // Delete the agent — the private timeline's cache entry and registry entry
        // should be evicted alongside the persisted row, not orphaned.
        try await manager.deleteInstance(id: instance.id, force: false)

        #expect(await timelineManager.getTimeline(id: instance.privateTimelineId) == nil,
               "Private timeline should be evicted from the TimelineManager cache")

        let fresh = await registry.history(for: instance.privateTimelineId)
        #expect(await fresh.appendedMessageCount == 0,
               "Prompt-history registry entry should be evicted, not orphaned")
    }
}
