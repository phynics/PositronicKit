import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import struct PositronicKit.Thread
import Synchronization
import Testing

/// PKRR-023 regression tests: `evictThreadFromMemory` is memory-only (cancels active work,
/// leaves persistence intact) and `deleteThreadPermanently` removes all persisted records
/// or reports partial cleanup. These guard against the original leak/race where the
/// `deleteThread` name suggested durable deletion but only evicted memory.
@Suite("Thread eviction & permanent deletion (PKRR-023)")
struct ThreadEvictionDeletionTests {

    // MARK: - Eviction is memory-only: cancels active work, preserves persistence

    @Test("evictThreadFromMemory cancels active work and leaves persistence intact (PKRR-023)")
    func evictCancelsWorkAndPreservesPersistence() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "a", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread()
        let agent = try await kit.agents.create(name: "Eviction Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let driver = kit.openThread(thread.id)

        // Seed a persisted message so we can prove eviction does not delete it.
        let seededMessage = ThreadMessage(
            threadID: thread.id,
            role: .user,
            content: "seed"
        )
        try await runtime.persistence.saveMessage(seededMessage)

        // Start an active stream.
        let stream = try await driver.send("hello")
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            do { for try await _ in stream {} } catch {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        // Evict — must cancel and drain the active task before tearing down state.
        await kit.threadManager.evictThreadFromMemory(id: thread.id)

        let terminated = streamTerminated.withLock { $0 }
        #expect(terminated, "Active stream must terminate after eviction")

        let activeAfter = await kit.threadManager.hasActiveTask(for: thread.id)
        #expect(!activeAfter, "No active task should survive eviction")

        // Cache evicted.
        #expect(await kit.threadManager.thread(id: thread.id) == nil)

        // Persistence intact — thread row, seeded message, and workspace all survive.
        let persistedThread = try #require(
            await runtime.persistence.fetchThread(id: thread.id)
        )
        #expect(persistedThread.id == thread.id)

        let persistedMessages = try await runtime.persistence.fetchMessages(for: thread.id)
        #expect(persistedMessages.contains { $0.content == "seed" },
                "Seeded message must survive eviction")

        let workspaceId = try #require(
            (try await kit.threadManager.getWorkspaces(for: thread.id)).primary?.id
        )
        let persistedWorkspace = try #require(
            await runtime.persistence.fetchWorkspace(id: workspaceId, includeTools: false)
        )
        #expect(persistedWorkspace.id == workspaceId)

        consumeTask.cancel()
    }

    @Test("evictThreadFromMemory does not delete the thread row or messages from persistence (PKRR-023)")
    func evictPreservesThreadRow() async throws {
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
        try await persistence.saveMessage(ThreadMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))

        await threadManager.evictThreadFromMemory(id: thread.id)

        #expect(await threadManager.thread(id: thread.id) == nil)
        let persisted = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persisted.id == thread.id)
        let messages = try await persistence.fetchMessages(for: thread.id)
        #expect(messages.count == 1)
    }

    // MARK: - Permanent deletion

    @Test("deleteThreadPermanently removes thread, messages, and workspace records (PKRR-023)")
    func permanentDeleteRemovesAllRecords() async throws {
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
        let workspaceId = try #require(
            (try await threadManager.getWorkspaces(for: thread.id)).primary?.id
        )

        try await persistence.saveMessage(ThreadMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))
        try await persistence.saveMessage(ThreadMessage(
            threadID: thread.id, role: .assistant, content: "hi there"
        ))

        let result = await threadManager.deleteThreadPermanently(id: thread.id)

        #expect(result.isComplete,
                "All stores should succeed; degradations: \(result.degradations)")
        #expect(result.degradations.isEmpty)

        // Memory evicted.
        #expect(await threadManager.thread(id: thread.id) == nil)

        // Persistence removed.
        #expect(try await persistence.fetchThread(id: thread.id) == nil)
        #expect(try await persistence.fetchMessages(for: thread.id).isEmpty)
        #expect(try await persistence.fetchWorkspace(id: workspaceId, includeTools: false) == nil)
    }

    @Test("permanent deletion removes canonical runtimeThread workspaces")
    func permanentDeleteRemovesCanonicalRuntimeThreadWorkspace() async throws {
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
        let thread = Thread()
        let canonicalWorkspace = WorkspaceReference(
            uri: .threadWorkspace(thread.id),
            location: .runtimeThread
        )
        try await persistence.saveWorkspace(canonicalWorkspace)
        try await persistence.saveThread(thread)
        try await threadManager.attachWorkspace(canonicalWorkspace.id, to: thread.id)

        let result = await threadManager.deleteThreadPermanently(id: thread.id)

        #expect(result.isComplete)
        #expect(try await persistence.fetchWorkspace(
            id: canonicalWorkspace.id,
            includeTools: false
        ) == nil)
    }

    @Test("permanent deletion preserves caller-owned attached workspace")
    func permanentDeletePreservesCallerOwnedAttachedWorkspace() async throws {
        let persistence = MockPersistenceService()
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let callerWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "user-mac", path: "/projects/app"),
            location: .attached,
            rootPath: workspaceRoot.path
        )
        try await persistence.saveWorkspace(callerWorkspace)

        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace
        )
        let thread = try await threadManager.createThread()
        try await threadManager.attachWorkspace(callerWorkspace.id, to: thread.id)

        let result = await threadManager.deleteThreadPermanently(id: thread.id)

        #expect(result.isComplete)
        #expect(try await persistence.fetchThread(id: thread.id) == nil)
        #expect(try await persistence.fetchWorkspace(
            id: callerWorkspace.id, includeTools: false
        )?.id == callerWorkspace.id)
        #expect(FileManager.default.fileExists(atPath: workspaceRoot.path))
    }

    @Test("deleteThreadPermanently refuses active work and succeeds after cancellation (PKRR-023)")
    func permanentDeleteWaitsForActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "b", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread()
        let agent = try await kit.agents.create(name: "Deletion Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let driver = kit.openThread(thread.id)

        let stream = try await driver.send("hello")
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            do { for try await _ in stream {} } catch {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        let result = await kit.threadManager.deleteThreadPermanently(id: thread.id)

        #expect(!result.isComplete)
        #expect(result.degradations.contains(where: { $0.operation == "deleteThreadPermanently.activeTurn" }))
        #expect(!streamTerminated.withLock { $0 })
        #expect(await kit.threadManager.hasActiveTask(for: thread.id))
        #expect(await kit.threadManager.thread(id: thread.id) != nil)
        #expect(try await runtime.persistence.fetchThread(id: thread.id) != nil)

        await driver.cancel()
        _ = await consumeTask.result
        if let activeTask = await kit.threadManager.activeTaskCompletion(for: thread.id) {
            _ = await activeTask.value
        }

        let retry = await kit.threadManager.deleteThreadPermanently(id: thread.id)
        #expect(retry.isComplete)
        #expect(try await runtime.persistence.fetchThread(id: thread.id) == nil)
    }

    @Test("deleteThreadPermanently reports partial cleanup when a store fails (PKRR-023)")
    func permanentDeleteReportsPartialCleanup() async throws {
        let failingThreadStore = FailingThreadPersistence(deleteFails: true)
        let backing = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: failingThreadStore,
                messageStore: backing,
                workspaceStore: backing,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryThreadRuntimeRepository(),
                toolPersistence: backing
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let thread = try await threadManager.createThread()
        let workspaceId = try #require(
            (try await threadManager.getWorkspaces(for: thread.id)).primary?.id
        )

        try await backing.saveMessage(ThreadMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))

        let result = await threadManager.deleteThreadPermanently(id: thread.id)

        // Partial: thread delete failed.
        #expect(!result.isComplete,
                "Should report incomplete cleanup when thread deletion fails")
        #expect(result.degradations.count == 1)
        let degradation = try #require(result.degradations.first)
        #expect(degradation.operation.contains("deleteThread"))

        // Workspaces are still cleaned up despite the thread failure — that cleanup is a
        // separate, independent step in `deleteThreadPermanently`.
        #expect(try await backing.fetchWorkspace(id: workspaceId, includeTools: false) == nil)

        // Messages are NOT cleaned up here: history deletion is now solely the cascade that
        // `threadStore.deleteThread(id:)` performs internally (H-01), and this test wires a
        // `threadStore` (`failingThreadStore`) that is a different object from `messageStore`
        // (`backing`) and throws before doing anything. `ThreadManager` no longer has a separate
        // `messageStore.deleteMessages(for:)` step to fall back on, so a host that splits its
        // thread store from its message store no longer gets an independent best-effort message
        // cleanup — it must use one `ThreadRuntimeRepository` for both, as the default facade
        // wiring now does.
        #expect(try await backing.fetchMessages(for: thread.id).count == 1)

        // Thread row was NOT removed (delete threw before delegating to backing).
        #expect(failingThreadStore.deleteAttemptCount == 1)
        #expect(try await failingThreadStore.fetchThread(id: thread.id) != nil)

        // Memory evicted regardless.
        #expect(await threadManager.thread(id: thread.id) == nil)
    }

    @Test("deleteThreadPermanently on an unknown thread is a no-op complete result (PKRR-023)")
    func permanentDeleteUnknownThread() async throws {
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
        let unknownId = UUID()

        let result = await threadManager.deleteThreadPermanently(id: unknownId)

        #expect(result.isComplete)
        #expect(result.degradations.isEmpty)
    }

    // MARK: - H-01 regression: default facade wiring must not orphan message history

    @Test("deleteThreadPermanently through the default public facade cascades message history (H-01)")
    func permanentDeleteThroughDefaultFacadeCascadesHistory() async throws {
        // Regression for H-01: `PositronicKit()` wires `messageStore` to the same
        // `InMemoryThreadRuntimeRepository` as `runtimeRepository` (append-only history), so
        // `deleteThreadPermanently` must no longer rely on `messageStore.deleteMessages(for:)` —
        // that call always throws `historyDeletionForbidden` there. Deleting the thread must
        // cascade the message history instead of silently leaving it orphaned and unreachable.
        let kit = PositronicKit()
        let handle = try await kit.threads.create(title: "probe")
        try await kit.runtimeRepository.saveMessage(ThreadMessage(
            threadID: handle.id, role: .user, content: "secret user text"
        ))

        let result = await kit.threadManager.deleteThreadPermanently(id: handle.id)

        #expect(result.isComplete, "deletion should fully succeed; degradations: \(result.degradations)")
        #expect(result.degradations.isEmpty)
        #expect(try await kit.runtimeRepository.fetchMessages(for: handle.id).isEmpty)
    }
}
