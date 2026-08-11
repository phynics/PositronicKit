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

    @Test("Creation rolls back partial writes", arguments: AgentCreationFailureStage.allCases)
    func createInstanceRollsBackPartialWrites(
        failingAt: AgentCreationFailureStage
    ) async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-agent-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let stores = AgentCreationFaultStore(failingAt: failingAt)
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: stores
        )
        let manager = AgentInstanceManager(
            repository: repository,
            stores: .init(
                instanceStore: stores,
                timelineStore: stores,
                messageStore: stores,
                workspaceStore: stores
            )
        )

        let thrown = await #expect(throws: InjectedAgentCreationFailure.self) {
            _ = try await manager.createInstance(
                name: "Rollback Agent",
                description: "Failure injection"
            )
        }
        #expect(thrown?.stage == failingAt)

        #expect(await stores.allInstances().isEmpty)
        #expect(await stores.allTimelines().isEmpty)
        #expect(await stores.allMessages().isEmpty)
        #expect(await stores.allWorkspaces().isEmpty)

        let agentsRoot = workspaceRoot.appendingPathComponent("agents", isDirectory: true)
        let remainingDirectories = (try? FileManager.default.contentsOfDirectory(
            at: agentsRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(remainingDirectories.isEmpty)

        let expectedCleanup: [String]
        switch failingAt {
        case .workspace:
            expectedCleanup = ["deleteWorkspace"]
        case .timeline:
            expectedCleanup = ["deleteTimeline", "deleteWorkspace"]
        case .instance:
            expectedCleanup = ["deleteAgentInstance", "deleteTimeline", "deleteWorkspace"]
        case .audit:
            expectedCleanup = [
                "deleteMessages", "deleteAgentInstance", "deleteTimeline", "deleteWorkspace",
            ]
        }
        #expect(await stores.cleanupOperations() == expectedCleanup)
    }

    @Test("Default in-memory stores protect attached agents")
    func defaultInMemoryStorePreventsDeletingAttachedAgentWithoutForce() async throws {
        let kit = PositronicKit()
        let timeline = try await kit.timelineManager.createTimeline(title: "Shared Timeline")
        let instance = try await kit.agentInstanceManager.createInstance(
            name: "Attached Agent",
            description: "Agent attached to a shared timeline"
        )

        try await kit.agentInstanceManager.attach(agentId: instance.id, to: timeline.id)

        let thrown = await #expect(throws: AgentInstanceError.self) {
            try await kit.agentInstanceManager.deleteInstance(id: instance.id, force: false)
        }
        if case let .hasAttachedTimelines(count)? = thrown {
            #expect(count == 1)
        } else {
            Issue.record("Expected deletion to report an attached timeline")
        }
        #expect(try await kit.agentInstanceManager.instance(id: instance.id) != nil)

        try await kit.agentInstanceManager.deleteInstance(id: instance.id, force: true)

        let remainingTimelines = try await kit.timelineManager.listTimelines()
        let remainingTimeline = try #require(remainingTimelines.first { $0.id == timeline.id })
        #expect(remainingTimeline.attachedAgentInstanceID == nil)
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

    @Test("Cleanup: deleteInstance preserves the agent when private-timeline deletion fails")
    func deleteInstanceDoesNotRemoveAgentWhenPrivateTimelineDeletionFails() async throws {
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

        let thrown = await #expect(throws: FailingStoreError.self) {
            try await manager.deleteInstance(id: instance.id, force: false)
        }
        if case .deleteFailed? = thrown {
            // Preserve the original typed persistence error for callers and retry logic.
        } else {
            Issue.record("Expected the private-timeline deletion error to be rethrown")
        }

        // The delete was attempted (and failed) — observable, not swallowed.
        #expect(timelineStore.deleteAttemptCount >= 1)

        // Failed cleanup leaves all records needed for a retry intact.
        #expect(try await instanceStore.fetchAgentInstance(id: instance.id) != nil)
        let workspaceID = try #require(instance.primaryWorkspaceID)
        #expect(try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false) != nil)
        #expect(try await timelineStore.fetchTimeline(id: instance.privateTimelineID) != nil)
    }
}

enum AgentCreationFailureStage: String, CaseIterable, Sendable, Equatable {
    case workspace
    case timeline
    case instance
    case audit
}

private struct InjectedAgentCreationFailure: Error, Sendable {
    let stage: AgentCreationFailureStage
}

/// One test-only store makes each creation stage fail after its write, so rollback also covers
/// stores that report an error after a durable write has occurred. The catalog must compensate
/// the workspace row itself before the manager ever receives a workspace reference.
private actor AgentCreationFaultStore: WorkspaceStore, TimelinePersistenceProtocol,
    MessageStoreProtocol, AgentInstanceStoreProtocol
{
    private let failingAt: AgentCreationFailureStage
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var timelines: [UUID: Timeline] = [:]
    private var messages: [ConversationMessage] = []
    private var instances: [UUID: AgentInstance] = [:]
    private var cleanupEvents: [String] = []

    init(failingAt: AgentCreationFailureStage) {
        self.failingAt = failingAt
    }

    func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        workspaces[workspace.id] = workspace
        if failingAt == .workspace {
            throw InjectedAgentCreationFailure(stage: .workspace)
        }
    }

    func fetchWorkspace(id: UUID, includeTools _: Bool) async throws -> WorkspaceReference? {
        workspaces[id]
    }

    func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        Array(workspaces.values)
    }

    func deleteWorkspace(id: UUID) async throws {
        cleanupEvents.append("deleteWorkspace")
        workspaces.removeValue(forKey: id)
    }

    func saveTimeline(_ timeline: Timeline) async throws {
        timelines[timeline.id] = timeline
        if failingAt == .timeline {
            throw InjectedAgentCreationFailure(stage: .timeline)
        }
    }

    func fetchTimeline(id: UUID) async throws -> Timeline? {
        timelines[id]
    }

    func fetchAllTimelines(includeArchived _: Bool) async throws -> [Timeline] {
        Array(timelines.values)
    }

    func deleteTimeline(id: UUID) async throws {
        cleanupEvents.append("deleteTimeline")
        timelines.removeValue(forKey: id)
    }

    func pruneTimelines(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }

    func saveMessage(_ message: ConversationMessage) async throws {
        messages.append(message)
        if failingAt == .audit {
            throw InjectedAgentCreationFailure(stage: .audit)
        }
    }

    func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        messages.filter { $0.timelineID == timelineId }
    }

    func deleteMessages(for timelineId: UUID) async throws {
        cleanupEvents.append("deleteMessages")
        messages.removeAll { $0.timelineID == timelineId }
    }

    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        []
    }

    func saveAgentInstance(_ instance: AgentInstance) async throws {
        instances[instance.id] = instance
        if failingAt == .instance {
            throw InjectedAgentCreationFailure(stage: .instance)
        }
    }

    func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        instances[id]
    }

    func fetchAllAgentInstances() async throws -> [AgentInstance] {
        Array(instances.values)
    }

    func deleteAgentInstance(id: UUID) async throws {
        cleanupEvents.append("deleteAgentInstance")
        instances.removeValue(forKey: id)
    }

    func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Timeline] {
        timelines.values.filter { $0.attachedAgentInstanceID == agentInstanceId }
    }

    func allInstances() -> [AgentInstance] {
        Array(instances.values)
    }

    func allTimelines() -> [Timeline] {
        Array(timelines.values)
    }

    func allMessages() -> [ConversationMessage] {
        messages
    }

    func allWorkspaces() -> [WorkspaceReference] {
        Array(workspaces.values)
    }

    func cleanupOperations() -> [String] {
        cleanupEvents
    }
}
