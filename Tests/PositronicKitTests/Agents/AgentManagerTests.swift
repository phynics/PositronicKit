import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.tags(.integration))
struct AgentManagerTests {
    private let mock = MockPersistenceService()

    @Test("Canonical agent queries return attached timelines")
    func canonicalTimelinesQuery() async throws {
        let kit = PKRuntime()
        let timeline = try await kit.timelineManager.createTimeline(title: "Attached")
        let agent = try await kit.agentManager.createAgent(
            name: "Timeline Agent",
            description: "Lists attached timelines"
        )
        try await kit.agentManager.attach(agentID: agent.id, to: timeline.id)

        let attached = try await kit.agentManager.timelines(attachedTo: agent.id)

        #expect(attached.map(\.id).contains(timeline.id))
    }

    @Test("combined Timeline creation leaves no row when durable creation fails")
    func combinedCreationRollsBackOnTimelineStoreFailure() async throws {
        let timelineStore = FailingTimelinePersistence(saveFails: true)
        let agentStore = MockPersistenceService()
        let workspaceStore = MockWorkspacePersistence()
        let messageStore = MockPersistenceService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryTimelineRuntimeRepository()
            ),
            workspaceProfile: .noWorkspace
        )
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: FileManager.default.temporaryDirectory,
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repository,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            ),
            timelineManager: timelineManager
        )
        let agent = Agent(
            name: "Atomic Agent",
            description: "Tests combined Timeline creation.",
            privateTimelineID: UUID()
        )
        try await agentStore.saveAgent(agent)

        let error = await #expect(throws: TimelineError.self) {
            _ = try await manager.createTimeline(title: "Should not persist", attaching: agent.id)
        }

        if case .unavailable? = error {
            // Expected: the Timeline store rejected the durable creation.
        }
        #expect(try await timelineStore.fetchAllTimelines(includeArchived: true).isEmpty)
    }

    @Test("Canonical error cases use their owning domains")
    func canonicalErrorIdentity() {
        let timelineID = UUID()
        let agentID = UUID()
        let timelineError = TimelineError.timelineNotFound
        let mismatch = TurnError.managedExecutionAgentMismatch(
            timelineID: timelineID,
            requestedAgentID: agentID,
            attachedAgentID: nil
        )

        #expect(timelineError.errorCode == 6001)
        #expect(timelineError.errorDomain == PKErrorDomain.timeline)
        #expect(mismatch.errorCode == 9023)
        #expect(mismatch.errorDomain == PKErrorDomain.turn)
        #expect(mismatch.errorDescription?.contains(timelineID.uuidString) == true)
    }

    @Test("Validation: Name too short")
    func nameTooShort() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await manager.createAgent(name: "Ab", description: "Valid desc")
        }
    }

    @Test("Validation: Description empty")
    func descriptionEmpty() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await manager.createAgent(name: "Valid Name", description: "  ")
        }
    }

    @Test("Robustness: Cannot attach to private timeline")
    func cannotAttachToPrivate() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = Agent(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let otherAgentId = UUID()
        let otherAgent = Agent(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let privateTimeline = TimelineRecord(id: UUID(), title: "Private", attachedAgentID: agentId, isPrivate: true)

        try await mock.saveAgent(agent)
        try await mock.saveAgent(otherAgent)
        try await mock.saveTimeline(privateTimeline)

        // Fails: attaching different agent to private timeline
        await #expect(throws: AgentError.self) {
            try await manager.attach(agentID: otherAgentId, to: privateTimeline.id)
        }

        // Succeeds: attaching owner (idempotent)
        try await manager.attach(agentID: agent.id, to: privateTimeline.id)
    }

    @Test("Robustness: Cannot detach agent from its own private timeline")
    func cannotDetachFromOwnPrivate() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = Agent(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let privateTimeline = TimelineRecord(id: agent.privateTimelineID, title: "Private", attachedAgentID: agentId, isPrivate: true)

        try await mock.saveAgent(agent)
        try await mock.saveTimeline(privateTimeline)

        await #expect(throws: AgentError.self) {
            try await manager.detach(agentID: agentId, from: privateTimeline.id)
        }
    }

    @Test("Creation: Agent is automatically attached to private timeline")
    func createAgentAttachesAgent() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let instance = try await manager.createAgent(name: "New Agent", description: "Desc")

        let timeline = try await mock.fetchTimeline(id: instance.privateTimelineID)
        #expect(timeline?.attachedAgentID == instance.id)
        #expect(timeline?.isPrivate == true)
    }

    @Test("Creation rolls back partial writes", arguments: AgentCreationFailureStage.allCases)
    func createAgentRollsBackPartialWrites(
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
        let manager = AgentManager(
            repository: repository,
            stores: .init(
                agentStore: stores,
                timelineStore: stores,
                messageStore: stores,
                workspaceStore: stores
            )
        )

        let thrown = await #expect(throws: InjectedAgentCreationFailure.self) {
            _ = try await manager.createAgent(
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
            expectedCleanup = ["deleteAgent", "deleteTimeline", "deleteWorkspace"]
        case .audit:
            expectedCleanup = [
                "deleteMessages", "deleteAgent", "deleteTimeline", "deleteWorkspace",
            ]
        }
        #expect(await stores.cleanupOperations() == expectedCleanup)
    }

    @Test("Concurrent attachments resolve conflicts from the authoritative Timeline state")
    func concurrentAttachmentsDoNotOverwriteEachOther() async throws {
        let agentStore = InMemoryAgentStore()
        let timelineStore = AgentAttachmentRaceTimelineStore()
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let repository = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repository,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let firstAgent = Agent(
            id: UUID(), name: "First Agent", description: "First",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        let secondAgent = Agent(
            id: UUID(), name: "Second Agent", description: "Second",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        let timeline = TimelineRecord(id: UUID(), title: "Shared")
        try await agentStore.saveAgent(firstAgent)
        try await agentStore.saveAgent(secondAgent)
        try await timelineStore.saveTimeline(timeline)
        await timelineStore.blockNextSave()

        // Hold the first mutation after it has entered the Timeline lane. The second call can
        // reach its preflight read in the old implementation, capturing the same stale snapshot.
        let first = Task {
            do {
                try await manager.attach(agentID: firstAgent.id, to: timeline.id)
                return true
            } catch {
                return false
            }
        }
        await timelineStore.waitUntilBlockedSave()

        let second = Task {
            do {
                try await manager.attach(agentID: secondAgent.id, to: timeline.id)
                return true
            } catch {
                return false
            }
        }

        // Let a stale preflight read happen if one exists, without assuming any ordering between
        // the two manager tasks. The first save remains blocked until this bounded handoff ends.
        for _ in 0..<1_000 {
            if await timelineStore.fetchCount >= 2 { break }
            await Task.yield()
        }
        await timelineStore.releaseBlockedSave()

        let outcomes = [await first.value, await second.value]
        #expect(outcomes.filter { $0 }.count == 1)
        let attachedAgentID = try await timelineStore.fetchTimeline(id: timeline.id)?.attachedAgentID
        #expect(attachedAgentID == firstAgent.id || attachedAgentID == secondAgent.id)
    }

    @Test("Default in-memory stores protect attached agents")
    func defaultInMemoryStorePreventsDeletingAttachedAgentWithoutForce() async throws {
        let kit = PKRuntime()
        let timeline = try await kit.timelineManager.createTimeline(title: "Shared Timeline")
        let instance = try await kit.agentManager.createAgent(
            name: "Attached Agent",
            description: "Agent attached to a shared timeline"
        )

        try await kit.agentManager.attach(agentID: instance.id, to: timeline.id)

        let thrown = await #expect(throws: AgentError.self) {
            try await kit.agentManager.deleteAgent(id: instance.id, force: false)
        }
        if case let .hasAttachedTimelines(count)? = thrown {
            #expect(count == 1)
        } else {
            Issue.record("Expected deletion to report an attached timeline")
        }
        #expect(try await kit.agentManager.agent(id: instance.id) != nil)

        try await kit.agentManager.deleteAgent(id: instance.id, force: true)

        let remainingTimelines = try await kit.timelineManager.listTimelines()
        let remainingTimeline = try #require(remainingTimelines.first { $0.id == timeline.id })
        #expect(remainingTimeline.attachedAgentID == nil)
    }

    @Test("Search: Find by name or description")
    func searchAgents() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                timelineStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agent1 = Agent(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceID: UUID(), privateTimelineID: UUID())
        let agent2 = Agent(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceID: UUID(), privateTimelineID: UUID())

        try await mock.saveAgent(agent1)
        try await mock.saveAgent(agent2)

        let resultsName = try await manager.searchAgents(query: "research")
        #expect(resultsName.count == 1)
        #expect(resultsName.first?.name == "Researcher")

        let resultsDesc = try await manager.searchAgents(query: "Swift")
        #expect(resultsDesc.count == 1)
        #expect(resultsDesc.first?.name == "Coder")

        let resultsEmpty = try await manager.searchAgents(query: "")
        #expect(resultsEmpty.count == 2)
    }

    @Test("Deletion: routes private-timeline deletion through TimelineManager when injected (PKR-3)")
    func deleteAgentEvictsTimelineManagerCacheAndRegistry() async throws {
        // Use the same in-memory stores across the TimelineManager and the
        // AgentManager so the private timeline created by the agent
        // manager is visible to the timeline manager's store and cache.
        let timelineStore = InMemoryTimelinePersistence()
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let agentStore = InMemoryAgentStore()
        let registry = TimelinePromptJournals()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryTimelineRuntimeRepository()
            ),
            workspaceProfile: .hostManaged(root: workspaceRoot),
            promptHistoryRegistry: registry
        )

        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            ),
            timelineManager: timelineManager
        )

        let instance = try await manager.createAgent(name: "Eviction Target", description: "Desc")

        // Hydrate the private timeline into the TimelineManager cache and populate the registry.
        try await timelineManager.hydrateTimeline(id: instance.privateTimelineID)
        #expect(await timelineManager.timeline(id: instance.privateTimelineID) != nil)

        let history = await registry.history(for: instance.privateTimelineID)
        await history.recordAppend(messageCount: 4, estimatedTokens: 120)
        #expect(await history.appendedMessageCount == 4)

        // Delete the agent — the private timeline's cache entry and registry entry
        // should be evicted alongside the persisted row, not orphaned.
        try await manager.deleteAgent(id: instance.id, force: false)

        #expect(await timelineManager.timeline(id: instance.privateTimelineID) == nil,
               "Private timeline should be evicted from the TimelineManager cache")

        let fresh = await registry.history(for: instance.privateTimelineID)
        #expect(await fresh.appendedMessageCount == 0,
               "Prompt-history registry entry should be evicted, not orphaned")
    }

    // MARK: - PKFLAKE-005: failing persistence must not be swallowed

    @Test("Audit log: attach survives a failing message-store save (PKFLAKE-005)")
    func attachSurvivesFailingAuditLog() async throws {
        let agentStore = InMemoryAgentStore()
        let timelineStore = InMemoryTimelinePersistence()
        let workspaceStore = InMemoryWorkspacePersistence()
        let messageStore = FailingMessageStore()
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = Agent(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        let timeline = TimelineRecord(id: UUID(), title: "Shared", isPrivate: false)
        try await agentStore.saveAgent(agent)
        try await timelineStore.saveTimeline(timeline)

        // attach must NOT throw just because the audit-log save failed.
        try await manager.attach(agentID: agentId, to: timeline.id)

        // The attach itself succeeded: the timeline now references the agent.
        let updated = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(updated?.attachedAgentID == agentId)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
        #expect(messageStore.attemptedMessages.first?.role == "system")
    }

    @Test("Audit log: detach survives a failing message-store save (PKFLAKE-005)")
    func detachSurvivesFailingAuditLog() async throws {
        let agentStore = InMemoryAgentStore()
        let timelineStore = InMemoryTimelinePersistence()
        let workspaceStore = InMemoryWorkspacePersistence()
        let messageStore = FailingMessageStore()
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = Agent(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateTimelineID: UUID()
        )
        // A non-private timeline the agent is already attached to.
        let timeline = TimelineRecord(
            id: UUID(), title: "Shared", attachedAgentID: agentId, isPrivate: false
        )
        try await agentStore.saveAgent(agent)
        try await timelineStore.saveTimeline(timeline)

        // detach must NOT throw just because the audit-log save failed.
        try await manager.detach(agentID: agentId, from: timeline.id)

        // The detach itself succeeded: the agent reference is cleared.
        let updated = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(updated?.attachedAgentID == nil)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
    }

    @Test("Cleanup: deleteAgent preserves the agent when private-timeline deletion fails")
    func deleteAgentDoesNotRemoveAgentWhenPrivateTimelineDeletionFails() async throws {
        let agentStore = InMemoryAgentStore()
        let timelineStore = FailingTimelinePersistence(deleteFails: true)
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: workspaceRoot,
            workspacePersistence: workspaceStore
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: agentStore,
                timelineStore: timelineStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let instance = try await manager.createAgent(name: "Del Target", description: "Desc")

        let thrown = await #expect(throws: FailingStoreError.self) {
            try await manager.deleteAgent(id: instance.id, force: false)
        }
        if case .deleteFailed? = thrown {
            // Preserve the original typed persistence error for callers and retry logic.
        } else {
            Issue.record("Expected the private-timeline deletion error to be rethrown")
        }

        // The delete was attempted (and failed) — observable, not swallowed.
        #expect(timelineStore.deleteAttemptCount >= 1)

        // Failed cleanup leaves all records needed for a retry intact.
        #expect(try await agentStore.fetchAgent(id: instance.id) != nil)
        let workspaceID = try #require(instance.primaryWorkspaceID)
        #expect(try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false) != nil)
        #expect(try await timelineStore.fetchTimeline(id: instance.privateTimelineID) != nil)
    }
}

private actor AgentAttachmentRaceTimelineStore: TimelinePersistenceProtocol {
    private var timelines: [UUID: TimelineRecord] = [:]
    private var blockNextSaveRequest = false
    private var saveBlocked = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Test-only actor gate.
    private var saveReleaseContinuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Test-only actor gate.
    private(set) var fetchCount = 0

    func saveTimeline(_ timeline: TimelineRecord) async throws {
        if blockNextSaveRequest {
            blockNextSaveRequest = false
            saveBlocked = true
            blockedSaveContinuation?.resume()
            blockedSaveContinuation = nil
            await withCheckedContinuation { continuation in
                saveReleaseContinuation = continuation
            }
        }
        timelines[timeline.id] = timeline
    }

    func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        fetchCount += 1
        return timelines[id]
    }

    func fetchAllTimelines(includeArchived _: Bool) async throws -> [TimelineRecord] {
        Array(timelines.values)
    }

    func deleteTimeline(id: UUID) async throws {
        timelines.removeValue(forKey: id)
    }

    func pruneTimelines(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }

    func blockNextSave() {
        blockNextSaveRequest = true
    }

    func waitUntilBlockedSave() async {
        guard !saveBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedSaveContinuation = continuation
        }
    }

    func releaseBlockedSave() {
        saveReleaseContinuation?.resume()
        saveReleaseContinuation = nil
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
    TimelineMessageStoreProtocol, AgentStoreProtocol
{
    private let failingAt: AgentCreationFailureStage
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var timelines: [UUID: TimelineRecord] = [:]
    private var messages: [TimelineMessage] = []
    private var instances: [UUID: Agent] = [:]
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

    func saveTimeline(_ timeline: TimelineRecord) async throws {
        timelines[timeline.id] = timeline
        if failingAt == .timeline {
            throw InjectedAgentCreationFailure(stage: .timeline)
        }
    }

    func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        timelines[id]
    }

    func fetchAllTimelines(includeArchived _: Bool) async throws -> [TimelineRecord] {
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

    func saveMessage(_ message: TimelineMessage) async throws {
        messages.append(message)
        if failingAt == .audit {
            throw InjectedAgentCreationFailure(stage: .audit)
        }
    }

    func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        messages.filter { $0.timelineID == timelineID }
    }

    func deleteMessages(for timelineID: UUID) async throws {
        cleanupEvents.append("deleteMessages")
        messages.removeAll { $0.timelineID == timelineID }
    }

    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        []
    }

    func saveAgent(_ instance: Agent) async throws {
        instances[instance.id] = instance
        if failingAt == .instance {
            throw InjectedAgentCreationFailure(stage: .instance)
        }
    }

    func fetchAgent(id: UUID) async throws -> Agent? {
        instances[id]
    }

    func fetchAllAgents() async throws -> [Agent] {
        Array(instances.values)
    }

    func deleteAgent(id: UUID) async throws {
        cleanupEvents.append("deleteAgent")
        instances.removeValue(forKey: id)
    }

    func fetchTimelines(attachedToAgent agentID: UUID) async throws -> [TimelineRecord] {
        timelines.values.filter { $0.attachedAgentID == agentID }
    }

    func allInstances() -> [Agent] {
        Array(instances.values)
    }

    func allTimelines() -> [TimelineRecord] {
        Array(timelines.values)
    }

    func allMessages() -> [TimelineMessage] {
        messages
    }

    func allWorkspaces() -> [WorkspaceReference] {
        Array(workspaces.values)
    }

    func cleanupOperations() -> [String] {
        cleanupEvents
    }
}
