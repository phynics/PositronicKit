import Foundation
import PKShared
import PKUtilities
import PKTestSupport
import struct PositronicKit.Thread
@testable import PositronicKit
import Testing

struct AgentInstanceManagerTests {
    private let mock = MockPersistenceService()

    @Test("Canonical agent queries return attached threads")
    func canonicalThreadsQuery() async throws {
        let kit = PositronicKit()
        let thread = try await kit.threadManager.createThread(title: "Attached")
        let agent = try await kit.agentInstanceManager.createInstance(
            name: "Thread Agent",
            description: "Lists attached threads"
        )
        try await kit.agentInstanceManager.attach(agentID: agent.id, to: thread.id)

        let attached = try await kit.agentInstanceManager.threads(attachedTo: agent.id)

        #expect(attached.map(\.id).contains(thread.id))
    }

    @Test("Canonical error cases preserve legacy identity")
    func canonicalErrorIdentity() {
        let threadID = UUID()
        let agentID = UUID()
        let threadError = ThreadError.threadNotFound
        let mismatch = AgentInstanceError.threadAgentMismatch(
            threadID: threadID,
            agentInstanceID: agentID,
            attachedAgentInstanceID: nil
        )

        #expect(threadError.errorCode == 6001)
        #expect(threadError.errorDomain == PKErrorDomain.thread)
        #expect(mismatch.errorCode == 5009)
        #expect(mismatch.errorDescription?.contains(threadID.uuidString) == true)
    }

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
                threadStore: mock,
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
                threadStore: mock,
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let otherAgentId = UUID()
        let otherAgent = AgentInstance(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let privateThread = Thread(id: UUID(), title: "Private", attachedAgentInstanceID: agentId, isPrivate: true)

        try await mock.saveAgentInstance(agent)
        try await mock.saveAgentInstance(otherAgent)
        try await mock.saveThread(privateThread)

        // Fails: attaching different agent to private thread
        await #expect(throws: AgentInstanceError.self) {
            try await manager.attach(agentID: otherAgentId, to: privateThread.id)
        }

        // Succeeds: attaching owner (idempotent)
        try await manager.attach(agentID: agent.id, to: privateThread.id)
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let privateThread = Thread(id: agent.privateThreadID, title: "Private", attachedAgentInstanceID: agentId, isPrivate: true)

        try await mock.saveAgentInstance(agent)
        try await mock.saveThread(privateThread)

        await #expect(throws: AgentInstanceError.self) {
            try await manager.detach(agentID: agentId, from: privateThread.id)
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let instance = try await manager.createInstance(name: "New Agent", description: "Desc")

        let thread = try await mock.fetchThread(id: instance.privateThreadID)
        #expect(thread?.attachedAgentInstanceID == instance.id)
        #expect(thread?.isPrivate == true)
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
                threadStore: stores,
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
        #expect(await stores.allThreads().isEmpty)
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
        case .thread:
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
        let thread = try await kit.threadManager.createThread(title: "Shared Timeline")
        let instance = try await kit.agentInstanceManager.createInstance(
            name: "Attached Agent",
            description: "Agent attached to a shared timeline"
        )

        try await kit.agentInstanceManager.attach(agentID: instance.id, to: thread.id)

        let thrown = await #expect(throws: AgentInstanceError.self) {
            try await kit.agentInstanceManager.deleteInstance(id: instance.id, force: false)
        }
        if case let .hasAttachedThreads(count)? = thrown {
            #expect(count == 1)
        } else if case let .hasAttachedTimelines(count)? = thrown {
            #expect(count == 1)
        } else {
            Issue.record("Expected deletion to report an attached thread")
        }
        #expect(try await kit.agentInstanceManager.instance(id: instance.id) != nil)

        try await kit.agentInstanceManager.deleteInstance(id: instance.id, force: true)

        let remainingThreads = try await kit.threadManager.listThreads()
        let remainingThread = try #require(remainingThreads.first { $0.id == thread.id })
        #expect(remainingThread.attachedAgentInstanceID == nil)
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agent1 = AgentInstance(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let agent2 = AgentInstance(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceID: UUID(), privateThreadID: UUID())

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
    func deleteInstanceEvictsThreadManagerCacheAndRegistry() async throws {
        // Use the same in-memory stores across the ThreadManager and the
        // AgentInstanceManager so the private thread created by the agent
        // manager is visible to the thread manager's store and cache.
        let threadStore = InMemoryThreadPersistence()
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let instanceStore = InMemoryAgentInstanceStore()
        let registry = ThreadPromptJournals()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let threadManager = ThreadManager(
            stores: .init(
                threadStore: threadStore,
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            ),
            threadManager: threadManager
        )

        let instance = try await manager.createInstance(name: "Eviction Target", description: "Desc")

        // Hydrate the private thread into the ThreadManager cache and populate the registry.
        try await threadManager.hydrateThread(id: instance.privateThreadID)
        #expect(await threadManager.thread(id: instance.privateThreadID) != nil)

        let history = await registry.history(for: instance.privateThreadID)
        await history.recordAppend(messageCount: 4, estimatedTokens: 120)
        #expect(await history.appendedMessageCount == 4)

        // Delete the agent — the private thread's cache entry and registry entry
        // should be evicted alongside the persisted row, not orphaned.
        try await manager.deleteInstance(id: instance.id, force: false)

        #expect(await threadManager.thread(id: instance.privateThreadID) == nil,
               "Private timeline should be evicted from the TimelineManager cache")

        let fresh = await registry.history(for: instance.privateThreadID)
        #expect(await fresh.appendedMessageCount == 0,
               "Prompt-history registry entry should be evicted, not orphaned")
    }

    // MARK: - PKFLAKE-005: failing persistence must not be swallowed

    @Test("Audit log: attach survives a failing message-store save (PKFLAKE-005)")
    func attachSurvivesFailingAuditLog() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let threadStore = InMemoryThreadPersistence()
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateThreadID: UUID()
        )
        let thread = Thread(id: UUID(), title: "Shared", isPrivate: false)
        try await instanceStore.saveAgentInstance(agent)
        try await threadStore.saveThread(thread)

        // attach must NOT throw just because the audit-log save failed.
        try await manager.attach(agentID: agentId, to: thread.id)

        // The attach itself succeeded: the thread now references the agent.
        let updated = try await threadStore.fetchThread(id: thread.id)
        #expect(updated?.attachedAgentInstanceID == agentId)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
        #expect(messageStore.attemptedMessages.first?.role == "system")
    }

    @Test("Audit log: detach survives a failing message-store save (PKFLAKE-005)")
    func detachSurvivesFailingAuditLog() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let threadStore = InMemoryThreadPersistence()
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = AgentInstance(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateThreadID: UUID()
        )
        // A non-private thread the agent is already attached to.
        let thread = Thread(
            id: UUID(), title: "Shared", attachedAgentInstanceID: agentId, isPrivate: false
        )
        try await instanceStore.saveAgentInstance(agent)
        try await threadStore.saveThread(thread)

        // detach must NOT throw just because the audit-log save failed.
        try await manager.detach(agentID: agentId, from: thread.id)

        // The detach itself succeeded: the agent reference is cleared.
        let updated = try await threadStore.fetchThread(id: thread.id)
        #expect(updated?.attachedAgentInstanceID == nil)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
    }

    @Test("Cleanup: deleteInstance preserves the agent when private-timeline deletion fails")
    func deleteInstanceDoesNotRemoveAgentWhenPrivateThreadDeletionFails() async throws {
        let instanceStore = InMemoryAgentInstanceStore()
        let threadStore = FailingThreadPersistence(deleteFails: true)
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
                threadStore: threadStore,
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
        #expect(threadStore.deleteAttemptCount >= 1)

        // Failed cleanup leaves all records needed for a retry intact.
        #expect(try await instanceStore.fetchAgentInstance(id: instance.id) != nil)
        let workspaceID = try #require(instance.primaryWorkspaceID)
        #expect(try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false) != nil)
        #expect(try await threadStore.fetchThread(id: instance.privateThreadID) != nil)
    }
}

enum AgentCreationFailureStage: String, CaseIterable, Sendable, Equatable {
    case workspace
    case thread
    case instance
    case audit
}

private struct InjectedAgentCreationFailure: Error, Sendable {
    let stage: AgentCreationFailureStage
}

/// One test-only store makes each creation stage fail after its write, so rollback also covers
/// stores that report an error after a durable write has occurred. The catalog must compensate
/// the workspace row itself before the manager ever receives a workspace reference.
private actor AgentCreationFaultStore: WorkspaceStore, ThreadPersistenceProtocol,
    MessageStoreProtocol, AgentInstanceStoreProtocol
{
    private let failingAt: AgentCreationFailureStage
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var threads: [UUID: Thread] = [:]
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

    func saveThread(_ thread: Thread) async throws {
        threads[thread.id] = thread
        if failingAt == .thread {
            throw InjectedAgentCreationFailure(stage: .thread)
        }
    }

    func fetchThread(id: UUID) async throws -> Thread? {
        threads[id]
    }

    func fetchAllThreads(includeArchived _: Bool) async throws -> [Thread] {
        Array(threads.values)
    }

    func deleteThread(id: UUID) async throws {
        cleanupEvents.append("deleteTimeline")
        threads.removeValue(forKey: id)
    }

    func pruneThreads(
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

    func fetchMessages(for threadID: UUID) async throws -> [ConversationMessage] {
        messages.filter { $0.threadID == threadID }
    }

    func deleteMessages(for threadID: UUID) async throws {
        cleanupEvents.append("deleteMessages")
        messages.removeAll { $0.threadID == threadID }
    }

    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
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

    func fetchThreads(attachedToAgent agentInstanceId: UUID) async throws -> [Thread] {
        threads.values.filter { $0.attachedAgentInstanceID == agentInstanceId }
    }

    func allInstances() -> [AgentInstance] {
        Array(instances.values)
    }

    func allThreads() -> [Thread] {
        Array(threads.values)
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
