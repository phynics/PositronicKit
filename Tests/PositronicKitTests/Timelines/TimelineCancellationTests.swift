import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

/// PKRR-002 cancellation invariants: `TimelineHandle.cancel()` must actually cancel the
/// stream-driving task, the registry entry must be removed on every terminal path,
/// eviction/deletion must cancel active work, and a stale request ID cannot cancel a newer turn.
// `.serialized`: cancellation invariants use wall-clock stream waits with a one-minute
// suite time limit. Serialization avoids timing interference between the cancellation
// scenarios (issue #155).
@Suite("Timeline cancellation invariants (PKRR-002)", .serialized, .timeLimit(.minutes(1)), .tags(.integration))
struct TimelineCancellationTests {
    // MARK: - 1. cancel() stops an active stream

    @Test("cancel() stops an active stream that was previously a no-op (PKRR-002)")
    func cancelStopsActiveStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "x", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunkCount = Mutex(0)

        let consumeTask = Task {
            defer { startedContinuation.finish() }
            for await event in stream {
                if event.textContent != nil {
                    chunkCount.withLock { $0 += 1 }
                    startedContinuation.yield(())
                    startedContinuation.finish()
                }
            }
        }

        var startedIterator = startedStream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil, "Should receive at least one chunk before cancel")

        // Cancel — this was a no-op before the fix.
        await driver.cancel()

        // The public TurnHandle stream must terminate after delivering its cancellation event.
        await consumeTask.value
        let finalChunkCount = chunkCount.withLock { $0 }

        // The stream was configured for 50 chunks with 50ms delays (~2.5s total).
        // After cancellation, only a handful should arrive — not all 50.
        #expect(finalChunkCount < 50, "Stream should stop producing chunks after cancel (got \(finalChunkCount))")

    }

    // MARK: - 2. Provider stream task receives cancellation

    @Test("The provider stream task receives cancellation (PKRR-002)")
    func providerStreamTaskReceivesCancellation() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "y", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunkCount = Mutex(0)

        let consumeTask = Task {
            defer { startedContinuation.finish() }
            for await event in stream {
                if event.textContent != nil {
                    chunkCount.withLock { $0 += 1 }
                    startedContinuation.yield(())
                    startedContinuation.finish()
                }
            }
        }

        var startedIterator = startedStream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil, "Provider stream should start before cancel")

        await driver.cancel()

        await consumeTask.value
        let finalChunkCount = chunkCount.withLock { $0 }

        #expect(finalChunkCount < 50, "Provider stream should stop after cancel (got \(finalChunkCount) chunks)")
    }

    // MARK: - 3. Registry entry removed on every terminal path

    @Test("Registry entry is removed after normal stream completion (PKRR-002)")
    func registryEntryRemovedAfterNormalCompletion() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        // Before sending, no active task.
        let activeBefore = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeBefore)

        let turn = try await driver.startTurn("hello")
        let events = await turn.events().collect()

        #expect(!events.isEmpty)
        if let activeTask = await kit.timelineManager.activeTaskCompletion(for: timeline.id) {
            _ = await activeTask.value
        }
        // After completion, the registry entry must be gone.
        let activeAfter = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeAfter)
    }

    @Test("Registry entry is removed after a cancelled stream terminates (PKRR-002)")
    func registryEntryRemovedAfterCancellation() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "z", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let consumeTask = Task {
            defer { startedContinuation.finish() }
            for await event in stream {
                if event.textContent != nil {
                    startedContinuation.yield(())
                    startedContinuation.finish()
                }
            }
        }

        var startedIterator = startedStream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil, "Stream should start before cancellation")

        let activeDuring = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(activeDuring, "Task should be active during streaming")
        let activeTask = try #require(await kit.timelineManager.activeTaskCompletion(for: timeline.id))

        await driver.cancel()
        await consumeTask.value
        _ = await activeTask.value
        #expect(await kit.timelineManager.hasActiveTask(for: timeline.id) == false, "Registry entry should be removed after cancellation")
    }

    // MARK: - 4. Eviction/deletion cancels active work

    @Test("evictTimelineFromMemory cancels active generation and awaits cleanup (PKRR-002)")
    func deleteTimelineCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "w", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunkCount = Mutex(0)
        let consumeTask = Task {
            defer { startedContinuation.finish() }
            for await event in stream {
                if event.textContent != nil {
                    chunkCount.withLock { $0 += 1 }
                    startedContinuation.yield(())
                    startedContinuation.finish()
                }
            }
        }

        var startedIterator = startedStream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil, "Stream should start before eviction")

        // Delete the timeline — this must cancel and await the active task.
        await kit.timelineManager.evictTimelineFromMemory(id: timeline.id)

        // evictTimelineFromMemory awaits bounded cleanup, so the stream should already be done.
        await consumeTask.value
        let finalChunkCount = chunkCount.withLock { $0 }
        #expect(finalChunkCount < 50, "Stream should stop after eviction (got \(finalChunkCount) chunks)")

        // Timeline is evicted from cache.
        let evicted = await kit.timelineManager.timeline(id: timeline.id)
        #expect(evicted == nil)

    }

    @Test("cleanupStaleTimelines cancels active generation and awaits cleanup (PKRR-002)")
    func cleanupStaleCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "v", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline()
        let agent = try await kit.agents.create(name: "Cancellation Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let stream = turn.events()

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunkCount = Mutex(0)
        let consumeTask = Task {
            defer { startedContinuation.finish() }
            for await event in stream {
                if event.textContent != nil {
                    chunkCount.withLock { $0 += 1 }
                    startedContinuation.yield(())
                    startedContinuation.finish()
                }
            }
        }

        var startedIterator = startedStream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil, "Stream should start before stale cleanup")

        // cleanupStaleTimelines(maxAge: 0) evicts all timelines (updatedAt > 0 seconds ago).
        await kit.timelineManager.cleanupStaleTimelines(maxAge: 0)

        await consumeTask.value
        let finalChunkCount = chunkCount.withLock { $0 }
        #expect(finalChunkCount < 50, "Stream should stop after eviction (got \(finalChunkCount) chunks)")

        let evicted = await kit.timelineManager.timeline(id: timeline.id)
        #expect(evicted == nil)

    }

    // MARK: - 5. Active Turn registration and stale cleanup

    @Test("A second active Turn registration is rejected without cancelling the first (PKRR-002)")
    func secondActiveTurnRegistrationIsRejected() async throws {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspaceRoot))
        let timelineID = UUID()

        let taskACancelled = Mutex(false)
        let taskBCancelled = Mutex(false)

        let turnA = UUID()
        let turnB = UUID()

        let (taskAWaitStream, taskAWaitContinuation) = AsyncStream<Void>.makeStream()
        let taskA = Task {
            await withTaskCancellationHandler {
                var iterator = taskAWaitStream.makeAsyncIterator()
                _ = await iterator.next()
            } onCancel: {
                taskACancelled.withLock { $0 = true }
            }
        }

        let (taskBWaitStream, taskBWaitContinuation) = AsyncStream<Void>.makeStream()
        let taskB = Task {
            await withTaskCancellationHandler {
                var iterator = taskBWaitStream.makeAsyncIterator()
                _ = await iterator.next()
            } onCancel: {
                taskBCancelled.withLock { $0 = true }
            }
        }

        let registeredA = await timelineManager.registerTask(taskA, turnID: turnA, for: timelineID)
        let registeredB = await timelineManager.registerTask(taskB, turnID: turnB, for: timelineID)
        #expect(registeredA)
        #expect(!registeredB)

        let rejectedCancelResult = await timelineManager.cancelGeneration(turnID: turnB, for: timelineID)
        #expect(!rejectedCancelResult, "A rejected Turn must not gain cancellation authority")

        await timelineManager.cancelGeneration(for: timelineID)
        taskAWaitContinuation.finish()
        _ = await taskA.value
        #expect(taskACancelled.withLock { $0 })
        #expect(!taskBCancelled.withLock { $0 })

        taskB.cancel()
        taskBWaitContinuation.finish()
        _ = await taskB.value
        await timelineManager.removeTask(turnID: turnA, for: timelineID)
    }

    @Test("A stale send's terminal cleanup does not evict a newer send's registry entry (PKRR-002)")
    func staleTerminalCleanupDoesNotEvictNewerSend() async throws {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceProfile: .hostManaged(root: workspaceRoot))
        let timelineID = UUID()

        let turnA = UUID()
        let turnB = UUID()

        let (taskAWaitStream, taskAWaitContinuation) = AsyncStream<Void>.makeStream()
        let taskA = Task {
            var iterator = taskAWaitStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        let (taskBWaitStream, taskBWaitContinuation) = AsyncStream<Void>.makeStream()
        let taskB = Task {
            var iterator = taskBWaitStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        await timelineManager.registerTask(taskA, turnID: turnA, for: timelineID)
        await timelineManager.removeTask(turnID: turnA, for: timelineID)
        taskA.cancel()
        taskAWaitContinuation.finish()
        _ = await taskA.value
        await timelineManager.registerTask(taskB, turnID: turnB, for: timelineID)

        // Simulate turn A's terminal cleanup (removeIfActive with stale turnID).
        await timelineManager.removeTask(turnID: turnA, for: timelineID)

        // Send B's entry should still be active.
        let stillActive = await timelineManager.hasActiveTask(for: timelineID)
        #expect(stillActive, "Newer turn's entry should survive stale terminal cleanup")

        // Clean up.
        await timelineManager.cancelGeneration(for: timelineID)
        await timelineManager.removeTask(turnID: turnB, for: timelineID)
        taskBWaitContinuation.finish()
        taskB.cancel()
        _ = await taskB.value
    }
}
