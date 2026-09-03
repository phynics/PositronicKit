import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
import struct PositronicKit.Thread
@testable import PositronicKit
import Testing

struct AgentManagerTests {
    private let mock = MockPersistenceService()

    @Test("Canonical agent queries return attached threads")
    func canonicalThreadsQuery() async throws {
        let kit = PositronicKit()
        let thread = try await kit.threadManager.createThread(title: "Attached")
        let agent = try await kit.agentManager.createAgent(
            name: "Thread Agent",
            description: "Lists attached threads"
        )
        try await kit.agentManager.attach(agentID: agent.id, to: thread.id)

        let attached = try await kit.agentManager.threads(attachedTo: agent.id)

        #expect(attached.map(\.id).contains(thread.id))
    }

    @Test("Canonical error cases use their owning domains")
    func canonicalErrorIdentity() {
        let threadID = UUID()
        let agentID = UUID()
        let threadError = ThreadError.threadNotFound
        let mismatch = TurnError.managedExecutionAgentMismatch(
            threadID: threadID,
            requestedAgentID: agentID,
            attachedAgentID: nil
        )

        #expect(threadError.errorCode == 6001)
        #expect(threadError.errorDomain == PKErrorDomain.thread)
        #expect(mismatch.errorCode == 9023)
        #expect(mismatch.errorDomain == PKErrorDomain.turn)
        #expect(mismatch.errorDescription?.contains(threadID.uuidString) == true)
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
                threadStore: mock,
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        await #expect(throws: AgentError.self) {
            _ = try await manager.createAgent(name: "Valid Name", description: "  ")
        }
    }

    @Test("Robustness: Cannot attach to private thread")
    func cannotAttachToPrivate() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = Agent(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let otherAgentId = UUID()
        let otherAgent = Agent(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let privateThread = Thread(id: UUID(), title: "Private", attachedAgentID: agentId, isPrivate: true)

        try await mock.saveAgent(agent)
        try await mock.saveAgent(otherAgent)
        try await mock.saveThread(privateThread)

        // Fails: attaching different agent to private thread
        await #expect(throws: AgentError.self) {
            try await manager.attach(agentID: otherAgentId, to: privateThread.id)
        }

        // Succeeds: attaching owner (idempotent)
        try await manager.attach(agentID: agent.id, to: privateThread.id)
    }

    @Test("Robustness: Cannot detach agent from its own private thread")
    func cannotDetachFromOwnPrivate() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agentId = UUID()
        let agent = Agent(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let privateThread = Thread(id: agent.privateThreadID, title: "Private", attachedAgentID: agentId, isPrivate: true)

        try await mock.saveAgent(agent)
        try await mock.saveThread(privateThread)

        await #expect(throws: AgentError.self) {
            try await manager.detach(agentID: agentId, from: privateThread.id)
        }
    }

    @Test("Creation: Agent is automatically attached to private thread")
    func createAgentAttachesAgent() async throws {
        let repo = DefaultWorkspaceCatalog(
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspacePersistence: mock
        )
        let manager = AgentManager(
            repository: repo,
            stores: .init(
                agentStore: mock,
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let instance = try await manager.createAgent(name: "New Agent", description: "Desc")

        let thread = try await mock.fetchThread(id: instance.privateThreadID)
        #expect(thread?.attachedAgentID == instance.id)
        #expect(thread?.isPrivate == true)
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
                threadStore: stores,
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
            expectedCleanup = ["deleteThread", "deleteWorkspace"]
        case .instance:
            expectedCleanup = ["deleteAgent", "deleteThread", "deleteWorkspace"]
        case .audit:
            expectedCleanup = [
                "deleteMessages", "deleteAgent", "deleteThread", "deleteWorkspace",
            ]
        }
        #expect(await stores.cleanupOperations() == expectedCleanup)
    }

    @Test("Default in-memory stores protect attached agents")
    func defaultInMemoryStorePreventsDeletingAttachedAgentWithoutForce() async throws {
        let kit = PositronicKit()
        let thread = try await kit.threadManager.createThread(title: "Shared Thread")
        let instance = try await kit.agentManager.createAgent(
            name: "Attached Agent",
            description: "Agent attached to a shared thread"
        )

        try await kit.agentManager.attach(agentID: instance.id, to: thread.id)

        let thrown = await #expect(throws: AgentError.self) {
            try await kit.agentManager.deleteAgent(id: instance.id, force: false)
        }
        if case let .hasAttachedThreads(count)? = thrown {
            #expect(count == 1)
        } else {
            Issue.record("Expected deletion to report an attached thread")
        }
        #expect(try await kit.agentManager.agent(id: instance.id) != nil)

        try await kit.agentManager.deleteAgent(id: instance.id, force: true)

        let remainingThreads = try await kit.threadManager.listThreads()
        let remainingThread = try #require(remainingThreads.first { $0.id == thread.id })
        #expect(remainingThread.attachedAgentID == nil)
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
                threadStore: mock,
                messageStore: mock,
                workspaceStore: mock
            )
        )

        let agent1 = Agent(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceID: UUID(), privateThreadID: UUID())
        let agent2 = Agent(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceID: UUID(), privateThreadID: UUID())

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

    @Test("Deletion: routes private-thread deletion through ThreadManager when injected (PKR-3)")
    func deleteAgentEvictsThreadManagerCacheAndRegistry() async throws {
        // Use the same in-memory stores across the ThreadManager and the
        // AgentManager so the private thread created by the agent
        // manager is visible to the thread manager's store and cache.
        let threadStore = InMemoryThreadPersistence()
        let messageStore = InMemoryMessageStore()
        let workspaceStore = InMemoryWorkspacePersistence()
        let agentStore = InMemoryAgentStore()
        let registry = ThreadPromptJournals()
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)

        let threadManager = ThreadManager(
            stores: .init(
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: InMemoryToolPersistence()
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            ),
            threadManager: threadManager
        )

        let instance = try await manager.createAgent(name: "Eviction Target", description: "Desc")

        // Hydrate the private thread into the ThreadManager cache and populate the registry.
        try await threadManager.hydrateThread(id: instance.privateThreadID)
        #expect(await threadManager.thread(id: instance.privateThreadID) != nil)

        let history = await registry.history(for: instance.privateThreadID)
        await history.recordAppend(messageCount: 4, estimatedTokens: 120)
        #expect(await history.appendedMessageCount == 4)

        // Delete the agent — the private thread's cache entry and registry entry
        // should be evicted alongside the persisted row, not orphaned.
        try await manager.deleteAgent(id: instance.id, force: false)

        #expect(await threadManager.thread(id: instance.privateThreadID) == nil,
               "Private thread should be evicted from the ThreadManager cache")

        let fresh = await registry.history(for: instance.privateThreadID)
        #expect(await fresh.appendedMessageCount == 0,
               "Prompt-history registry entry should be evicted, not orphaned")
    }

    // MARK: - PKFLAKE-005: failing persistence must not be swallowed

    @Test("Audit log: attach survives a failing message-store save (PKFLAKE-005)")
    func attachSurvivesFailingAuditLog() async throws {
        let agentStore = InMemoryAgentStore()
        let threadStore = InMemoryThreadPersistence()
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = Agent(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateThreadID: UUID()
        )
        let thread = Thread(id: UUID(), title: "Shared", isPrivate: false)
        try await agentStore.saveAgent(agent)
        try await threadStore.saveThread(thread)

        // attach must NOT throw just because the audit-log save failed.
        try await manager.attach(agentID: agentId, to: thread.id)

        // The attach itself succeeded: the thread now references the agent.
        let updated = try await threadStore.fetchThread(id: thread.id)
        #expect(updated?.attachedAgentID == agentId)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
        #expect(messageStore.attemptedMessages.first?.role == "system")
    }

    @Test("Audit log: detach survives a failing message-store save (PKFLAKE-005)")
    func detachSurvivesFailingAuditLog() async throws {
        let agentStore = InMemoryAgentStore()
        let threadStore = InMemoryThreadPersistence()
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
                threadStore: threadStore,
                messageStore: messageStore,
                workspaceStore: workspaceStore
            )
        )

        let agentId = UUID()
        let agent = Agent(
            id: agentId, name: "Audit Agent", description: "Desc",
            primaryWorkspaceID: UUID(), privateThreadID: UUID()
        )
        // A non-private thread the agent is already attached to.
        let thread = Thread(
            id: UUID(), title: "Shared", attachedAgentID: agentId, isPrivate: false
        )
        try await agentStore.saveAgent(agent)
        try await threadStore.saveThread(thread)

        // detach must NOT throw just because the audit-log save failed.
        try await manager.detach(agentID: agentId, from: thread.id)

        // The detach itself succeeded: the agent reference is cleared.
        let updated = try await threadStore.fetchThread(id: thread.id)
        #expect(updated?.attachedAgentID == nil)

        // The audit-log save was attempted (and failed) — observable, not swallowed.
        #expect(messageStore.attemptedMessages.count == 1)
    }

    @Test("Cleanup: deleteAgent preserves the agent when private-thread deletion fails")
    func deleteAgentDoesNotRemoveAgentWhenPrivateThreadDeletionFails() async throws {
        let agentStore = InMemoryAgentStore()
        let threadStore = FailingThreadPersistence(deleteFails: true)
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
                threadStore: threadStore,
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
            Issue.record("Expected the private-thread deletion error to be rethrown")
        }

        // The delete was attempted (and failed) — observable, not swallowed.
        #expect(threadStore.deleteAttemptCount >= 1)

        // Failed cleanup leaves all records needed for a retry intact.
        #expect(try await agentStore.fetchAgent(id: instance.id) != nil)
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
    ThreadMessageStoreProtocol, AgentStoreProtocol
{
    private let failingAt: AgentCreationFailureStage
    private var workspaces: [UUID: WorkspaceReference] = [:]
    private var threads: [UUID: Thread] = [:]
    private var messages: [ThreadMessage] = []
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
        cleanupEvents.append("deleteThread")
        threads.removeValue(forKey: id)
    }

    func pruneThreads(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }

    func saveMessage(_ message: ThreadMessage) async throws {
        messages.append(message)
        if failingAt == .audit {
            throw InjectedAgentCreationFailure(stage: .audit)
        }
    }

    func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
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

    func fetchThreads(attachedToAgent agentId: UUID) async throws -> [Thread] {
        threads.values.filter { $0.attachedAgentID == agentId }
    }

    func allInstances() -> [Agent] {
        Array(instances.values)
    }

    func allThreads() -> [Thread] {
        Array(threads.values)
    }

    func allMessages() -> [ThreadMessage] {
        messages
    }

    func allWorkspaces() -> [WorkspaceReference] {
        Array(workspaces.values)
    }

    func cleanupOperations() -> [String] {
        cleanupEvents
    }
}
