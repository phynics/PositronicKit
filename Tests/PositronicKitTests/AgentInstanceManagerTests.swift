import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

struct AgentInstanceManagerTests {
    private let mock = MockPersistenceService()

    @Test("Validation: Name too short")
    func nameTooShort() async throws {
        let repo = DefaultWorkspaceCatalog(
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
        let repo = DefaultWorkspaceCatalog(
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
        let repo = DefaultWorkspaceCatalog(
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
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let otherAgentId = UUID()
        let otherAgent = AgentInstance(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let privateTimeline = Timeline(id: UUID(), title: "Private", attachedAgentInstanceID: agentId, isPrivate: true)

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
        let repo = DefaultWorkspaceCatalog(
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
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let privateTimeline = Timeline(id: agent.privateTimelineID, title: "Private", attachedAgentInstanceID: agentId, isPrivate: true)

        try await mock.saveAgentInstance(agent)
        try await mock.saveTimeline(privateTimeline)

        await #expect(throws: AgentInstanceError.self) {
            try await manager.detach(agentId: agentId, from: privateTimeline.id)
        }
    }

    @Test("Creation: Agent is automatically attached to private timeline")
    func createInstanceAttachesAgent() async throws {
        let repo = DefaultWorkspaceCatalog(
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

        let timeline = try await mock.fetchTimeline(id: instance.privateTimelineID)
        #expect(timeline?.attachedAgentInstanceID == instance.id)
        #expect(timeline?.isPrivate == true)
    }

    @Test("Search: Find by name or description")
    func searchInstances() async throws {
        let repo = DefaultWorkspaceCatalog(
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

        let agent1 = AgentInstance(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let agent2 = AgentInstance(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceID: UUID(), privateTimelineID: UUID())

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
        let registry = TimelinePromptJournals()
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

        let repo = DefaultWorkspaceCatalog(
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
        try await timelineManager.hydrateTimeline(id: instance.privateTimelineID)
        #expect(await timelineManager.timeline(id: instance.privateTimelineID) != nil)

        let history = await registry.history(for: instance.privateTimelineID)
        await history.recordAppend(messageCount: 4, estimatedTokens: 120)
        #expect(await history.appendedMessageCount == 4)

        // Delete the agent — the private timeline's cache entry and registry entry
        // should be evicted alongside the persisted row, not orphaned.
        try await manager.deleteInstance(id: instance.id, force: false)

        #expect(await timelineManager.timeline(id: instance.privateTimelineID) == nil,
               "Private timeline should be evicted from the TimelineManager cache")

        let fresh = await registry.history(for: instance.privateTimelineID)
        #expect(await fresh.appendedMessageCount == 0,
               "Prompt-history registry entry should be evicted, not orphaned")
    }

    // MARK: - PKFLAKE-005: failing persistence must not be swallowed

    @Test("Audit log: attach survives a failing message-store save (PKFLAKE-005)")
    func attachSurvivesFailingAuditLog() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let timelineStore = InMemoryTimelinePersistence()
        let workspaceStore = InMemoryWorkspacePersistence()
        let messageStore = FailingMessageStore()
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: workspaceStore
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: instanceStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        let timeline = Timeline(id: UUID(), title: "Shared", isPrivate: false)
        try await instanceStore.saveAgentInstance(agent)
        try await timelineStore.saveTimeline(timeline)

        // attach must NOT throw just because the audit-log save failed.
        try await manager.attach(agentId: agentId, to: timeline.id)

        // The attach itself succeeded: the timeline now references the agent.
        let updated = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(updated?.attachedAgentInstanceID == agentId)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
        #expect(messageStore.attemptedMessages.first?.role == "system")
    }

    @Test("Audit log: detach survives a failing message-store save (PKFLAKE-005)")
    func detachSurvivesFailingAuditLog() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let timelineStore = InMemoryTimelinePersistence()
        let workspaceStore = InMemoryWorkspacePersistence()
        let messageStore = FailingMessageStore()
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: workspaceStore
        )
        let manager = AgentInstanceManager(
            repository: repo,
            stores: .init(
                instanceStore: instanceStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        // A non-private timeline the agent is already attached to.
        let timeline = Timeline(
            id: UUID(), title: "Shared", attachedAgentInstanceID: agentId, isPrivate: false
        )
        try await instanceStore.saveAgentInstance(agent)
        try await timelineStore.saveTimeline(timeline)

        // detach must NOT throw just because the audit-log save failed.
        try await manager.detach(agentId: agentId, from: timeline.id)

        // The detach itself succeeded: the agent reference is cleared.
        let updated = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(updated?.attachedAgentInstanceID == nil)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
    }

    @Test("Cleanup: deleteInstance survives a failing private-timeline delete (PKFLAKE-005)")
    func deleteInstanceSurvivesFailingTimelineDelete() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let timelineStore = FailingTimelinePersistence(deleteFails: true)
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let repo = DefaultWorkspaceCatalog(
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
            )
        )

        let instance = try await manager.createInstance(name: "Del Target", description: "Desc")

        // deleteInstance must NOT throw just because the private-timeline row delete failed.
        try await manager.deleteInstance(id: instance.id, force: false)

        // The delete was attempted (and failed) — observable, not swallowed.
        #expect(timelineStore.deleteAttemptCount >= 1)

        // The agent instance record itself is gone: teardown proceeded past the failed cleanup.
        #expect(try await instanceStore.fetchAgentInstance(id: instance.id) == nil)
    }
}
