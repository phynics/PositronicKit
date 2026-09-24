import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

/// PKRR-023 regression tests: `evictTimelineFromMemory` is memory-only (cancels active work,
/// leaves persistence intact) and `deleteTimelinePermanently` removes all persisted records
/// or reports partial cleanup. These guard against the original leak/race where the
/// `deleteTimeline` name suggested durable deletion but only evicted memory.
@Suite("Timeline eviction & permanent deletion (PKRR-023)", .tags(.integration))
struct TimelineEvictionDeletionTests {

    // MARK: - Eviction is memory-only: cancels active work, preserves persistence

    @Test("evictTimelineFromMemory cancels active work and leaves persistence intact (PKRR-023)")
    func evictCancelsWorkAndPreservesPersistence() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "a", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Eviction Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        // Seed a persisted message so we can prove eviction does not delete it.
        let seededMessage = TimelineMessage(
            timelineID: timeline.id,
            role: .user,
            content: "seed"
        )
        try await runtime.persistence.saveMessage(seededMessage)

        // Start an active stream.
        let turn = try await driver.startTurn("hello")
        let stream = turn.events()
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            for await _ in stream {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        // Evict — must cancel and drain the active task before tearing down state.
        await kit.timelineManager.evictTimelineFromMemory(id: timeline.id)
        _ = await consumeTask.value

        let terminated = streamTerminated.withLock { $0 }
        #expect(terminated, "Active stream must terminate after eviction")

        let activeAfter = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeAfter, "No active task should survive eviction")

        // Cache evicted.
        #expect(await kit.timelineManager.timeline(id: timeline.id) == nil)

        // Persistence intact — timeline row, seeded message, and workspace all survive.
        let persistedTimeline = try #require(
            await runtime.persistence.fetchTimeline(id: timeline.id)
        )
        #expect(persistedTimeline.id == timeline.id)

        let persistedMessages = try await runtime.persistence.fetchMessages(for: timeline.id)
        #expect(persistedMessages.contains { $0.content == "seed" },
                "Seeded message must survive eviction")

        let workspaceId = try #require(
            (try await kit.timelineManager.getWorkspaces(for: timeline.id)).primary?.id
        )
        let persistedWorkspace = try #require(
            await runtime.persistence.fetchWorkspace(id: workspaceId, includeTools: false)
        )
        #expect(persistedWorkspace.id == workspaceId)

        consumeTask.cancel()
    }

    @Test("evictTimelineFromMemory does not delete the timeline row or messages from persistence (PKRR-023)")
    func evictPreservesTimelineRow() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let timeline = try await timelineManager.createTimeline()
        try await persistence.saveMessage(TimelineMessage(
            timelineID: timeline.id, role: .user, content: "hello"
        ))

        await timelineManager.evictTimelineFromMemory(id: timeline.id)

        #expect(await timelineManager.timeline(id: timeline.id) == nil)
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
        let messages = try await persistence.fetchMessages(for: timeline.id)
        #expect(messages.count == 1)
    }

    // MARK: - Permanent deletion

    @Test("deleteTimelinePermanently removes timeline, messages, and workspace records (PKRR-023)")
    func permanentDeleteRemovesAllRecords() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let timeline = try await timelineManager.createTimeline()
        let workspaceId = try #require(
            (try await timelineManager.getWorkspaces(for: timeline.id)).primary?.id
        )

        try await persistence.saveMessage(TimelineMessage(
            timelineID: timeline.id, role: .user, content: "hello"
        ))
        try await persistence.saveMessage(TimelineMessage(
            timelineID: timeline.id, role: .assistant, content: "hi there"
        ))

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)

        #expect(result.isComplete,
                "All stores should succeed; degradations: \(result.degradations)")
        #expect(result.degradations.isEmpty)

        // Memory evicted.
        #expect(await timelineManager.timeline(id: timeline.id) == nil)

        // Persistence removed.
        #expect(try await persistence.fetchTimeline(id: timeline.id) == nil)
        #expect(try await persistence.fetchMessages(for: timeline.id).isEmpty)
        #expect(try await persistence.fetchWorkspace(id: workspaceId, includeTools: false) == nil)
    }

    @Test("permanent deletion removes canonical runtimeTimeline workspaces")
    func permanentDeleteRemovesCanonicalRuntimeTimelineWorkspace() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let timeline = TimelineRecord()
        let canonicalWorkspace = WorkspaceReference(
            uri: .timelineWorkspace(timeline.id),
            location: .runtimeTimeline
        )
        try await persistence.saveWorkspace(canonicalWorkspace)
        try await persistence.saveTimeline(timeline)
        try await timelineManager.attachWorkspace(canonicalWorkspace.id, to: timeline.id)

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)

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

        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .noWorkspace
        )
        let timeline = try await timelineManager.createTimeline()
        try await timelineManager.attachWorkspace(callerWorkspace.id, to: timeline.id)

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)

        #expect(result.isComplete)
        #expect(try await persistence.fetchTimeline(id: timeline.id) == nil)
        #expect(try await persistence.fetchWorkspace(
            id: callerWorkspace.id, includeTools: false
        )?.id == callerWorkspace.id)
        #expect(FileManager.default.fileExists(atPath: workspaceRoot.path))
    }

    @Test("deleteTimelinePermanently refuses active work and succeeds after cancellation (PKRR-023)")
    func permanentDeleteWaitsForActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "b", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Deletion Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            for await _ in stream {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        let result = await kit.timelineManager.deleteTimelinePermanently(id: timeline.id)

        #expect(!result.isComplete)
        #expect(result.degradations.contains(where: { $0.operation == "deleteTimelinePermanently.activeTurn" }))
        #expect(!streamTerminated.withLock { $0 })
        #expect(await kit.timelineManager.hasActiveTask(for: timeline.id))
        #expect(await kit.timelineManager.timeline(id: timeline.id) != nil)
        #expect(try await runtime.persistence.fetchTimeline(id: timeline.id) != nil)

        await driver.cancel()
        _ = await consumeTask.result
        if let activeTask = await kit.timelineManager.activeTaskCompletion(for: timeline.id) {
            _ = await activeTask.value
        }

        let retry = await kit.timelineManager.deleteTimelinePermanently(id: timeline.id)
        #expect(retry.isComplete)
        #expect(try await runtime.persistence.fetchTimeline(id: timeline.id) == nil)
    }

    @Test("deleteTimelinePermanently reports partial cleanup when a store fails (PKRR-023)")
    func permanentDeleteReportsPartialCleanup() async throws {
        let failingTimelineStore = FailingTimelinePersistence(deleteFails: true)
        let backing = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: failingTimelineStore,
                messageStore: backing,
                workspaceStore: backing,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: InMemoryTimelineRuntimeRepository()
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let timeline = try await timelineManager.createTimeline()
        let workspaceId = try #require(
            (try await timelineManager.getWorkspaces(for: timeline.id)).primary?.id
        )

        try await backing.saveMessage(TimelineMessage(
            timelineID: timeline.id, role: .user, content: "hello"
        ))

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)

        // Partial: timeline delete failed.
        #expect(!result.isComplete,
                "Should report incomplete cleanup when timeline deletion fails")
        #expect(result.degradations.count == 1)
        let degradation = try #require(result.degradations.first)
        #expect(degradation.operation.contains("deleteTimeline"))

        // Workspaces are still cleaned up despite the timeline failure — that cleanup is a
        // separate, independent step in `deleteTimelinePermanently`.
        #expect(try await backing.fetchWorkspace(id: workspaceId, includeTools: false) == nil)

        // Messages are NOT cleaned up here: history deletion is now solely the cascade that
        // `timelineStore.deleteTimeline(id:)` performs internally (H-01), and this test wires a
        // `timelineStore` (`failingTimelineStore`) that is a different object from `messageStore`
        // (`backing`) and throws before doing anything. `TimelineManager` no longer has a separate
        // `messageStore.deleteMessages(for:)` step to fall back on, so a host that splits its
        // timeline store from its message store no longer gets an independent best-effort message
        // cleanup — it must use one `TimelineRuntimeRepository` for both, as the default facade
        // wiring now does.
        #expect(try await backing.fetchMessages(for: timeline.id).count == 1)

        // Timeline row was NOT removed (delete threw before delegating to backing).
        #expect(failingTimelineStore.deleteAttemptCount == 1)
        #expect(try await failingTimelineStore.fetchTimeline(id: timeline.id) != nil)

        // Memory evicted regardless.
        #expect(await timelineManager.timeline(id: timeline.id) == nil)
    }

    @Test("deleteTimelinePermanently on an unknown timeline is a no-op complete result (PKRR-023)")
    func permanentDeleteUnknownTimeline() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: persistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        let unknownId = UUID()

        let result = await timelineManager.deleteTimelinePermanently(id: unknownId)

        #expect(result.isComplete)
        #expect(result.degradations.isEmpty)
    }

    // MARK: - H-01 regression: default facade wiring must not orphan message history

    @Test("deleteTimelinePermanently through the default public facade cascades message history (H-01)")
    func permanentDeleteThroughDefaultFacadeCascadesHistory() async throws {
        // Regression for H-01: `PKRuntime()` wires `messageStore` to the same
        // `InMemoryTimelineRuntimeRepository` as `runtimeRepository` (append-only history), so
        // `deleteTimelinePermanently` must no longer rely on `messageStore.deleteMessages(for:)` —
        // that call always throws `historyDeletionForbidden` there. Deleting the timeline must
        // cascade the message history instead of silently leaving it orphaned and unreachable.
        let kit = PKRuntime()
        let handle = try await kit.timelines.create(title: "probe")
        try await kit.runtimeRepository.saveMessage(TimelineMessage(
            timelineID: handle.id, role: .user, content: "secret user text"
        ))

        let result = await kit.timelineManager.deleteTimelinePermanently(id: handle.id)

        #expect(result.isComplete, "deletion should fully succeed; degradations: \(result.degradations)")
        #expect(result.degradations.isEmpty)
        #expect(try await kit.runtimeRepository.fetchMessages(for: handle.id).isEmpty)
    }
}
