import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

struct ThreadManagerTests {
    @Test("manager parameter labels remain source compatible")
    func managerParameterLabels() async throws {
        let manager = ThreadManager(workspaceProfile: .noWorkspace)
        let thread = try await manager.createThread(title: "Legacy labels")

        _ = try await manager.getHistory(for: thread.id)
        _ = await manager.enabledTools(for: thread.id)
        _ = await manager.enableTool(id: "missing", for: thread.id)
        _ = await manager.disableTool(id: "missing", for: thread.id)
        #expect(try await manager.getToolSource(toolId: "missing", for: thread.id) == nil)

        let task = Task<Void, Never> {}
        let requestID = UUID()
        await manager.registerTask(task, turnID: requestID, for: thread.id)
        _ = await manager.cancelGeneration(turnID: requestID, for: thread.id)
        await manager.cancelGeneration(for: thread.id)
        await manager.removeTask(turnID: requestID, for: thread.id)
        await manager.cancelActiveTaskAndAwait(for: thread.id)
    }

    @Test("attachment parameter labels remain source compatible")
    func attachmentParameterLabels() async throws {
        let manager = ThreadManager(workspaceProfile: .noWorkspace)
        let thread = try await manager.createThread(title: "Legacy attachments")
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(parsing: "workspace://legacy-labels")!,
            location: .attached
        )
        try await manager.importWorkspace(workspace)

        try await manager.attachWorkspace(workspace.id, to: thread.id)
        #expect(try await manager.getWorkspaces(for: thread.id).attached.map(\.id) == [workspace.id])
        try await manager.detachWorkspace(workspace.id, from: thread.id)
        #expect(try await manager.getWorkspaces(for: thread.id).attached.isEmpty)
    }

    @Test("canonical thread manager owns lifecycle and policy surface")
    func canonicalThreadManagerSurface() async throws {
        let persistence = MockPersistenceService()
        let threadStore = MockThreadPersistence()
        let manager = ThreadManager(
            stores: .init(
                threadStore: threadStore,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace
        )

        let workspace = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(parsing: "workspace://canonical")!,
            location: .attached
        )
        try await manager.importWorkspace(workspace)

        let thread = try await manager.createThread(title: "Lifecycle")
        #expect(await manager.thread(id: thread.id)?.id == thread.id)

        try await manager.updateThreadTitle(thread.id, title: "Renamed")
        try await manager.attachWorkspace(workspace.id, to: thread.id)
        let result = await manager.deleteThreadPermanently(id: thread.id)

        #expect(result.threadID == thread.id)
    }

    @Test("canonical thread manager exposes store and runtime policy names")
    func canonicalThreadManagerTypes() {
        let policy = RuntimeToolPolicy(
            installThreadObservationTools: false,
            installThreadSendTool: false
        )
        #expect(policy.installThreadObservationTools == false)
        #expect(policy.installThreadSendTool == false)

        let workspaceStore = InMemoryWorkspacePersistence()
        let stores = ThreadManager.Stores(
            threadStore: InMemoryThreadPersistence(),
            messageStore: InMemoryMessageStore(),
            workspaceStore: workspaceStore,
            workspaceBindingRepository: workspaceStore,
            runtimeRepository: InMemoryThreadRuntimeRepository(),
            toolPersistence: InMemoryToolPersistence()
        )
        _ = stores.threadStore
    }

    @Test("importWorkspace persists into the store the manager validates against")
    func importWorkspacePersistsIntoBackingStore() async throws {
        let store = InMemoryWorkspacePersistence()
        let manager = ThreadManager(
            stores: .init(
                threadStore: InMemoryThreadPersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: store,
                workspaceBindingRepository: store,
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: .noWorkspace
        )
        let reference = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(parsing: "workspace://import")!,
            location: .runtime
        )
        try await manager.importWorkspace(reference)
        // A subsequent attachWorkspace must no longer fail the store gate, and the
        // reference is visible via the manager's store.
        #expect(try await store.fetchWorkspace(id: reference.id, includeTools: false) != nil)
    }

    @Test("Test Session Creation")
    func sessionCreation() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await threadManager.createThread()

        #expect(session.id != UUID(), "Session should have an ID")

        let retrievedSession = await threadManager.thread(id: session.id)
        #expect(retrievedSession != nil, "Should be able to retrieve created session")
        #expect(retrievedSession?.id == session.id)

    }

    @Test("Test Stale Session Cleanup")
    func cleanup() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await threadManager.createThread()

        await threadManager.cleanupStaleThreads(maxAge: 0)

        let retrieved = await threadManager.thread(id: session.id)
        #expect(retrieved == nil, "Session should be cleaned up")
    }

    @Test("evictThreadFromMemory(id:) evicts the prompt-history registry entry, not just the cache")
    func deleteThreadEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = ThreadPromptJournals()
        let threadManager = ThreadManager(
            workspaceProfile: .hostManaged(root: workspace.root),
            promptHistoryRegistry: registry
        )

        let session = try await threadManager.createThread()

        // Populate the registry with distinguishing state.
        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 3, estimatedTokens: 90)
        #expect(await history.appendedMessageCount == 3)

        // evictThreadFromMemory is the runtime-eviction seam: cache + registry.
        await threadManager.evictThreadFromMemory(id: session.id)

        // Cache evicted.
        #expect(await threadManager.thread(id: session.id) == nil)

        // Registry evicted — re-fetch yields a fresh instance with reset state.
        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
        #expect(await fresh.lastDiff == nil)
    }

    @Test("cleanupStaleThreads(maxAge:) also drops the prompt-history registry entry")
    func cleanupStaleEvictsPromptHistory() async throws {
        let workspace = TestWorkspace()
        let registry = ThreadPromptJournals()
        let threadManager = ThreadManager(
            workspaceProfile: .hostManaged(root: workspace.root),
            promptHistoryRegistry: registry
        )

        let session = try await threadManager.createThread()

        let history = await registry.history(for: session.id)
        await history.recordAppend(messageCount: 5, estimatedTokens: 150)
        #expect(await history.appendedMessageCount == 5)

        await threadManager.cleanupStaleThreads(maxAge: 0)

        #expect(await threadManager.thread(id: session.id) == nil)

        let fresh = await registry.history(for: session.id)
        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
    }

    @Test("evictThreadFromMemory(id:) with no injected registry still evicts the cache")
    func deleteThreadWithoutRegistry() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        let session = try await threadManager.createThread()

        await threadManager.evictThreadFromMemory(id: session.id)

        #expect(await threadManager.thread(id: session.id) == nil)
    }

    @Test("Test Task Registration and Cancellation")
    func taskCancellation() async {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspaceRoot))
        let threadID = UUID()

        let isCancelled = Mutex(false)

        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            isCancelled.withLock { $0 = true }
        }

        await threadManager.registerTask(task, turnID: UUID(), for: threadID)

        // Verify it's in the registry (using internal access if possible, or just through behavior)
        await threadManager.cancelGeneration(for: threadID)

        // Poll until the task observes cancellation, with a generous CI-safe deadline
        // (guards only against a genuine hang, not normal scheduling variance).
        let deadline = ContinuousClock.now + .seconds(5)
        while !isCancelled.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }

        let cancelledFinal = isCancelled.withLock { $0 }
        #expect(cancelledFinal, "Task should have been cancelled")
    }

    @Test("hydrateThread short-circuits when a tool manager is already cached")
    func hydrateShortCircuit() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await threadManager.createThread()
        try await persistence.deleteThread(id: thread.id)

        try await threadManager.hydrateThread(id: thread.id)
        #expect(await threadManager.thread(id: thread.id) != nil)
    }

    @Test("hydrateThread throws threadNotFound when persistence has no thread")
    func hydrateMissing() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        do {
            try await threadManager.hydrateThread(id: UUID())
            Issue.record("Expected threadNotFound")
        } catch ThreadError.threadNotFound {
            // ok
        }
    }

    @Test("updateThreadTitle mutates cache and persistence")
    func updateTitle() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await threadManager.createThread()

        try await threadManager.updateThreadTitle(thread.id, title: "renamed")

        let cached = try #require(await threadManager.thread(id: thread.id))
        #expect(cached.title == "renamed")
        let persisted = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persisted.title == "renamed")
    }

    @Test("updateThreadTitle for a missing thread throws threadNotFound")
    func updateTitleMissing() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        do {
            try await threadManager.updateThreadTitle(UUID(), title: "x")
            Issue.record("Expected threadNotFound")
        } catch ThreadError.threadNotFound {
            // ok
        }
    }

    @Test("cleanupStaleThreads evicts from memory but not persistence")
    func cleanupStaleDoesNotPersistDelete() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )

        let thread = try await threadManager.createThread()

        await threadManager.cleanupStaleThreads(maxAge: 0)

        #expect(await threadManager.thread(id: thread.id) == nil)
        let persisted = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persisted.id == thread.id)
    }

    @Test("createThread creates Notes/Welcome.md and Notes/Project.md in the working directory")
    func createThreadWritesDefaultNotes() async throws {
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(workspaceProfile: .hostManaged(root: workspace.root))

        let thread = try await threadManager.createThread()

        let workingDir = try #require(thread.workingDirectory)
        let notesDir = URL(fileURLWithPath: workingDir).appendingPathComponent("Notes")
        let welcome = try String(
            contentsOf: notesDir.appendingPathComponent("Welcome.md"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: notesDir.appendingPathComponent("Project.md"),
            encoding: .utf8
        )
        #expect(welcome.contains("Welcome"))
        #expect(project.contains("Active Objective"))
    }

    // Note: the four `createToolManager` policy tests previously here were migrated to
    // `RuntimeToolPolicyFactoryTests` (under `Tests/PositronicKitTests/Services/`), which
    // exercises the extracted `RuntimeToolPolicyFactory` directly with in-memory stores —
    // satisfying PKARCH-003 AC #4 without needing a `ThreadManager` instance.
}
