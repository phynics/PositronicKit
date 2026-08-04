import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

/// PKRR-023 regression tests: `evictTimelineFromMemory` is memory-only (cancels active work,
/// leaves persistence intact) and `deleteTimelinePermanently` removes all persisted records
/// or reports partial cleanup. These guard against the original leak/race where the
/// `deleteTimeline` name suggested durable deletion but only evicted memory.
@Suite("Timeline eviction & permanent deletion (PKRR-023)")
struct TimelineEvictionDeletionTests {

    // MARK: - Eviction is memory-only: cancels active work, preserves persistence

    @Test("evictTimelineFromMemory cancels active work and leaves persistence intact (PKRR-023)")
    func evictCancelsWorkAndPreservesPersistence() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "a", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        // Seed a persisted message so we can prove eviction does not delete it.
        let seededMessage = ConversationMessage(
            timelineId: timeline.id,
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
        await kit.timelineManager.evictTimelineFromMemory(id: timeline.id)

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

        let workspaceId = try #require(timeline.attachedWorkspaceIDs.first)
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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let timeline = try await timelineManager.createTimeline()
        try await persistence.saveMessage(ConversationMessage(
            timelineId: timeline.id, role: .user, content: "hello"
        ))

        await timelineManager.evictTimelineFromMemory(id: timeline.id)

        #expect(await timelineManager.timeline(id: timeline.id) == nil)
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
        let messages = try await persistence.fetchMessages(for: timeline.id)
        #expect(messages.count == 1)
    }

    // MARK: - Deprecated alias

    @Test("deleteTimeline(id:) is a deprecated alias that still evicts memory (PKRR-023)")
    func deleteTimelineDeprecatedAliasEvicts() async throws {
        let persistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let timeline = try await timelineManager.createTimeline()

        await timelineManager.evictTimelineFromMemory(id: timeline.id)

        #expect(await timelineManager.timeline(id: timeline.id) == nil)
        // Persistence untouched.
        let persisted = try #require(await persistence.fetchTimeline(id: timeline.id))
        #expect(persisted.id == timeline.id)
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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let timeline = try await timelineManager.createTimeline()
        let workspaceId = try #require(timeline.attachedWorkspaceIDs.first)

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timeline.id, role: .user, content: "hello"
        ))
        try await persistence.saveMessage(ConversationMessage(
            timelineId: timeline.id, role: .assistant, content: "hi there"
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

    @Test("deleteTimelinePermanently cancels active work before deleting records (PKRR-023)")
    func permanentDeleteCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "b", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.positronicKit
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")
        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            do { for try await _ in stream {} } catch {}
            streamTerminated.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(150))

        let result = await kit.timelineManager.deleteTimelinePermanently(id: timeline.id)

        #expect(result.isComplete)
        let terminated = streamTerminated.withLock { $0 }
        #expect(terminated, "Active stream must terminate after permanent deletion")
        let activeAfter = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeAfter, "No active task should survive permanent deletion")
        #expect(await kit.timelineManager.timeline(id: timeline.id) == nil)
        #expect(try await runtime.persistence.fetchTimeline(id: timeline.id) == nil)

        consumeTask.cancel()
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
                toolPersistence: backing
            ),
            workspaceRoot: workspace.root
        )
        let timeline = try await timelineManager.createTimeline()
        let workspaceId = try #require(timeline.attachedWorkspaceIDs.first)

        try await backing.saveMessage(ConversationMessage(
            timelineId: timeline.id, role: .user, content: "hello"
        ))

        let result = await timelineManager.deleteTimelinePermanently(id: timeline.id)

        // Partial: timeline delete failed.
        #expect(!result.isComplete,
                "Should report incomplete cleanup when timeline delete fails")
        #expect(result.degradations.count == 1)
        let degradation = try #require(result.degradations.first)
        #expect(degradation.operation.contains("deleteTimeline"))

        // Messages and workspaces were still cleaned up despite the timeline failure.
        #expect(try await backing.fetchMessages(for: timeline.id).isEmpty)
        #expect(try await backing.fetchWorkspace(id: workspaceId, includeTools: false) == nil)

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
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root
        )
        let unknownId = UUID()

        let result = await timelineManager.deleteTimelinePermanently(id: unknownId)

        #expect(result.isComplete)
        #expect(result.degradations.isEmpty)
    }
}
