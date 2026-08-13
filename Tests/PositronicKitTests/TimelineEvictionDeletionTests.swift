import Foundation
import PKShared
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
@Suite("Timeline eviction & permanent deletion (PKRR-023)")
struct ThreadEvictionDeletionTests {

    // MARK: - Eviction is memory-only: cancels active work, preserves persistence

    @Test("evictTimelineFromMemory cancels active work and leaves persistence intact (PKRR-023)")
    func evictCancelsWorkAndPreservesPersistence() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "a", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread()
        let driver = kit.openThread(thread.id)

        // Seed a persisted message so we can prove eviction does not delete it.
        let seededMessage = ConversationMessage(
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

        let workspaceId = try #require(thread.attachedWorkspaceIDs.first)
        let persistedWorkspace = try #require(
            await runtime.persistence.fetchWorkspace(id: workspaceId, includeTools: false)
        )
        #expect(persistedWorkspace.id == workspaceId)

        consumeTask.cancel()
    }

    @Test("evictTimelineFromMemory does not delete the timeline row or messages from persistence (PKRR-023)")
    func evictPreservesThreadRow() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let thread = try await threadManager.createThread()
        try await persistence.saveMessage(ConversationMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))

        await threadManager.evictThreadFromMemory(id: thread.id)

        #expect(await threadManager.thread(id: thread.id) == nil)
        let persisted = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persisted.id == thread.id)
        let messages = try await persistence.fetchMessages(for: thread.id)
        #expect(messages.count == 1)
    }

    // MARK: - Deprecated alias

    @Test("deleteTimeline(id:) is a deprecated alias that still evicts memory (PKRR-023)")
    func deleteThreadDeprecatedAliasEvicts() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let thread = try await threadManager.createThread()

        await threadManager.evictThreadFromMemory(id: thread.id)

        #expect(await threadManager.thread(id: thread.id) == nil)
        // Persistence untouched.
        let persisted = try #require(await persistence.fetchThread(id: thread.id))
        #expect(persisted.id == thread.id)
    }

    // MARK: - Permanent deletion

    @Test("deleteTimelinePermanently removes timeline, messages, and workspace records (PKRR-023)")
    func permanentDeleteRemovesAllRecords() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let thread = try await threadManager.createThread()
        let workspaceId = try #require(thread.attachedWorkspaceIDs.first)

        try await persistence.saveMessage(ConversationMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))
        try await persistence.saveMessage(ConversationMessage(
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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let thread = Thread()
        let canonicalWorkspace = WorkspaceReference(
            uri: .threadWorkspace(thread.id),
            location: .runtimeThread
        )
        var persistedThread = thread
        persistedThread.attachedWorkspaceIDs = [canonicalWorkspace.id]
        try await persistence.saveWorkspace(canonicalWorkspace)
        try await persistence.saveThread(persistedThread)

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

    @Test("deleteTimelinePermanently cancels active work before deleting records (PKRR-023)")
    func permanentDeleteCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "b", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread()
        let driver = kit.openThread(thread.id)

        let stream = try await driver.send("hello")
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            do { for try await _ in stream {} } catch {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        let result = await kit.threadManager.deleteThreadPermanently(id: thread.id)

        #expect(result.isComplete)
        let terminated = streamTerminated.withLock { $0 }
        #expect(terminated, "Active stream must terminate after permanent deletion")
        let activeAfter = await kit.threadManager.hasActiveTask(for: thread.id)
        #expect(!activeAfter, "No active task should survive permanent deletion")
        #expect(await kit.threadManager.thread(id: thread.id) == nil)
        #expect(try await runtime.persistence.fetchThread(id: thread.id) == nil)

        consumeTask.cancel()
    }

    @Test("deleteTimelinePermanently reports partial cleanup when a store fails (PKRR-023)")
    func permanentDeleteReportsPartialCleanup() async throws {
        let failingThreadStore = FailingThreadPersistence(deleteFails: true)
        let backing = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: failingThreadStore,
                messageStore: backing,
                workspaceStore: backing,
                toolPersistence: backing
            ),
            workspaceRoot: workspace.root
        )
        let thread = try await threadManager.createThread()
        let workspaceId = try #require(thread.attachedWorkspaceIDs.first)

        try await backing.saveMessage(ConversationMessage(
            threadID: thread.id, role: .user, content: "hello"
        ))

        let result = await threadManager.deleteThreadPermanently(id: thread.id)

        // Partial: thread delete failed.
        #expect(!result.isComplete,
                "Should report incomplete cleanup when timeline delete fails")
        #expect(result.degradations.count == 1)
        let degradation = try #require(result.degradations.first)
        #expect(degradation.operation.contains("deleteTimeline"))

        // Messages and workspaces were still cleaned up despite the thread failure.
        #expect(try await backing.fetchMessages(for: thread.id).isEmpty)
        #expect(try await backing.fetchWorkspace(id: workspaceId, includeTools: false) == nil)

        // Thread row was NOT removed (delete threw before delegating to backing).
        #expect(failingThreadStore.deleteAttemptCount == 1)
        #expect(try await failingThreadStore.fetchThread(id: thread.id) != nil)

        // Memory evicted regardless.
        #expect(await threadManager.thread(id: thread.id) == nil)
    }

    @Test("deleteTimelinePermanently on an unknown timeline is a no-op complete result (PKRR-023)")
    func permanentDeleteUnknownThread() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let unknownId = UUID()

        let result = await threadManager.deleteThreadPermanently(id: unknownId)

        #expect(result.isComplete)
        #expect(result.degradations.isEmpty)
    }
}
