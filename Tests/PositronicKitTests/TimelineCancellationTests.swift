import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

/// PKRR-002 cancellation invariants: `TimelineDriver.cancel()` must actually cancel the
/// stream-driving task, the registry entry must be removed on every terminal path,
/// eviction/deletion must cancel active work, and a stale send ID cannot cancel a newer send.
@Suite("Timeline cancellation invariants (PKRR-002)", .serialized)
struct TimelineCancellationTests {
    // MARK: - 1. cancel() stops an active stream

    @Test("cancel() stops an active stream that was previously a no-op (PKRR-002)")
    func cancelStopsActiveStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "x", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")

        let sawFirstChunk = Mutex(false)
        let streamTerminated = Mutex(false)
        let chunkCount = Mutex(0)

        let consumeTask = Task {
            do {
                for try await event in stream {
                    if event.textContent != nil {
                        sawFirstChunk.withLock { $0 = true }
                        chunkCount.withLock { $0 += 1 }
                    }
                }
                streamTerminated.withLock { $0 = true }
            } catch {
                streamTerminated.withLock { $0 = true }
            }
        }

        // Wait for at least one chunk to prove the stream is active.
        let firstChunkDeadline = ContinuousClock.now + .seconds(5)
        while !sawFirstChunk.withLock({ $0 }), ContinuousClock.now < firstChunkDeadline {
            await Task.yield()
        }
        let gotFirstChunk = sawFirstChunk.withLock { $0 }
        #expect(gotFirstChunk, "Should receive at least one chunk before cancel")

        // Cancel — this was a no-op before the fix.
        await driver.cancel()

        // The stream must terminate (either via .generationCancelled or a thrown error).
        let terminateDeadline = ContinuousClock.now + .seconds(10)
        while !streamTerminated.withLock({ $0 }), ContinuousClock.now < terminateDeadline {
            await Task.yield()
        }
        let terminated = streamTerminated.withLock { $0 }
        let finalChunkCount = chunkCount.withLock { $0 }

        #expect(terminated, "Stream should terminate after cancel")
        // The stream was configured for 50 chunks with 50ms delays (~2.5s total).
        // After cancellation, only a handful should arrive — not all 50.
        #expect(finalChunkCount < 50, "Stream should stop producing chunks after cancel (got \(finalChunkCount))")

        consumeTask.cancel()
    }

    // MARK: - 2. Provider stream task receives cancellation

    @Test("The provider stream task receives cancellation (PKRR-002)")
    func providerStreamTaskReceivesCancellation() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "y", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")

        let streamTerminated = Mutex(false)
        let chunkCount = Mutex(0)

        let consumeTask = Task {
            do {
                for try await event in stream {
                    if event.textContent != nil {
                        chunkCount.withLock { $0 += 1 }
                    }
                }
                streamTerminated.withLock { $0 = true }
            } catch is CancellationError {
                streamTerminated.withLock { $0 = true }
            } catch {
                streamTerminated.withLock { $0 = true }
            }
        }

        // Let the stream start producing.
        try await Task.sleep(for: .milliseconds(150))

        await driver.cancel()

        let deadline = ContinuousClock.now + .seconds(10)
        while !streamTerminated.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let terminated = streamTerminated.withLock { $0 }
        let finalChunkCount = chunkCount.withLock { $0 }

        #expect(terminated, "Stream should terminate after cancel")
        #expect(finalChunkCount < 50, "Provider stream should stop after cancel (got \(finalChunkCount) chunks)")

        consumeTask.cancel()
    }

    // MARK: - 3. Registry entry removed on every terminal path

    @Test("Registry entry is removed after normal stream completion (PKRR-002)")
    func registryEntryRemovedAfterNormalCompletion() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        // Before sending, no active task.
        let activeBefore = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeBefore)

        let events = try await driver.send("hello").collect()

        #expect(!events.isEmpty)
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
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")

        let streamTerminated = Mutex(false)
        let consumeTask = Task {
            do {
                for try await _ in stream {}
            } catch {}
            streamTerminated.withLock { $0 = true }
        }

        // Let the stream start.
        try await Task.sleep(for: .milliseconds(150))

        let activeDuring = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(activeDuring, "Task should be active during streaming")

        await driver.cancel()

        let deadline = ContinuousClock.now + .seconds(10)
        while !streamTerminated.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let terminated = streamTerminated.withLock { $0 }
        #expect(terminated, "Stream should terminate after cancel")

        // After cancellation terminates, the registry entry must be gone.
        let activeAfter = await kit.timelineManager.hasActiveTask(for: timeline.id)
        #expect(!activeAfter, "Registry entry should be removed after cancellation")

        consumeTask.cancel()
    }

    // MARK: - 4. Eviction/deletion cancels active work

    @Test("evictTimelineFromMemory cancels active generation and awaits cleanup (PKRR-002)")
    func deleteTimelineCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "w", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")

        let streamTerminated = Mutex(false)
        let chunkCount = Mutex(0)
        let consumeTask = Task {
            do {
                for try await event in stream {
                    if event.textContent != nil {
                        chunkCount.withLock { $0 += 1 }
                    }
                }
            } catch {}
            streamTerminated.withLock { $0 = true }
        }

        // Let the stream start.
        try await Task.sleep(for: .milliseconds(150))

        // Delete the timeline — this must cancel and await the active task.
        await kit.timelineManager.evictTimelineFromMemory(id: timeline.id)

        // evictTimelineFromMemory awaits bounded cleanup, so the stream should already be done.
        let terminated = streamTerminated.withLock { $0 }
        let finalChunkCount = chunkCount.withLock { $0 }
        #expect(terminated, "Stream should terminate after deleteTimeline")
        #expect(finalChunkCount < 50, "Stream should stop after eviction (got \(finalChunkCount) chunks)")

        // Timeline is evicted from cache.
        let evicted = await kit.timelineManager.timeline(id: timeline.id)
        #expect(evicted == nil)

        consumeTask.cancel()
    }

    @Test("cleanupStaleTimelines cancels active generation and awaits cleanup (PKRR-002)")
    func cleanupStaleCancelsActiveWork() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [Array(repeating: "v", count: 50)]
        runtime.llm.mockClient.nextStreamWait = 0.05
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline()
        let driver = kit.openTimeline(timeline.id)

        let stream = try await driver.send("hello")

        let streamTerminated = Mutex(false)
        let chunkCount = Mutex(0)
        let consumeTask = Task {
            do {
                for try await event in stream {
                    if event.textContent != nil {
                        chunkCount.withLock { $0 += 1 }
                    }
                }
            } catch {}
            streamTerminated.withLock { $0 = true }
        }

        // Let the stream start.
        try await Task.sleep(for: .milliseconds(150))

        // cleanupStaleTimelines(maxAge: 0) evicts all timelines (updatedAt > 0 seconds ago).
        await kit.timelineManager.cleanupStaleTimelines(maxAge: 0)

        let terminated = streamTerminated.withLock { $0 }
        let finalChunkCount = chunkCount.withLock { $0 }
        #expect(terminated, "Stream should terminate after cleanupStaleTimelines")
        #expect(finalChunkCount < 50, "Stream should stop after eviction (got \(finalChunkCount) chunks)")

        let evicted = await kit.timelineManager.timeline(id: timeline.id)
        #expect(evicted == nil)

        consumeTask.cancel()
    }

    // MARK: - 5. A stale send ID cannot cancel a newer send

    @Test("A stale send ID cannot cancel a newer send (PKRR-002)")
    func staleSendIDCannotCancelNewerSend() async throws {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceRoot: workspaceRoot)
        let timelineId = UUID()

        let taskACancelled = Mutex(false)
        let taskBCancelled = Mutex(false)

        let sendA = UUID()
        let sendB = UUID()

        let taskA = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            taskACancelled.withLock { $0 = true }
        }

        let taskB = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            taskBCancelled.withLock { $0 = true }
        }

        // Register send A, then replace it with send B (replacement-send behavior).
        await timelineManager.registerTask(taskA, sendID: sendA, for: timelineId)
        await timelineManager.registerTask(taskB, sendID: sendB, for: timelineId)

        // Task A should have been cancelled by the replacement registration.
        let aDeadline = ContinuousClock.now + .seconds(5)
        while !taskACancelled.withLock({ $0 }), ContinuousClock.now < aDeadline {
            await Task.yield()
        }
        let aCancelled = taskACancelled.withLock { $0 }
        #expect(aCancelled, "Task A should be cancelled when superseded by send B")

        // Attempt to cancel send A (stale) — must NOT cancel send B.
        let staleCancelResult = await timelineManager.cancelGeneration(sendID: sendA, for: timelineId)
        #expect(!staleCancelResult, "Stale send ID should not match the active send")

        // Task B should NOT be cancelled.
        try await Task.sleep(for: .milliseconds(100))
        let bCancelledEarly = taskBCancelled.withLock { $0 }
        #expect(!bCancelledEarly, "Task B should not be cancelled by a stale send ID")

        // Now cancel the active send B — this should work.
        await timelineManager.cancelGeneration(for: timelineId)
        let bDeadline = ContinuousClock.now + .seconds(5)
        while !taskBCancelled.withLock({ $0 }), ContinuousClock.now < bDeadline {
            await Task.yield()
        }
        let bCancelledFinal = taskBCancelled.withLock { $0 }
        #expect(bCancelledFinal, "Task B should be cancelled by cancelGeneration(for:)")

        // Clean up registry.
        await timelineManager.removeTask(sendID: sendB, for: timelineId)
    }

    @Test("A stale send's terminal cleanup does not evict a newer send's registry entry (PKRR-002)")
    func staleTerminalCleanupDoesNotEvictNewerSend() async throws {
        let workspaceRoot = getTestWorkspaceRoot().appendingPathComponent(UUID().uuidString)
        let timelineManager = TimelineManager(workspaceRoot: workspaceRoot)
        let timelineId = UUID()

        let sendA = UUID()
        let sendB = UUID()

        let taskA = Task {
            while !Task.isCancelled { await Task.yield() }
        }

        let taskB = Task {
            while !Task.isCancelled { await Task.yield() }
        }

        await timelineManager.registerTask(taskA, sendID: sendA, for: timelineId)
        await timelineManager.registerTask(taskB, sendID: sendB, for: timelineId)

        // Simulate send A's terminal cleanup (removeIfActive with stale sendID).
        await timelineManager.removeTask(sendID: sendA, for: timelineId)

        // Send B's entry should still be active.
        let stillActive = await timelineManager.hasActiveTask(for: timelineId)
        #expect(stillActive, "Newer send's entry should survive stale terminal cleanup")

        // Clean up.
        await timelineManager.cancelGeneration(for: timelineId)
        await timelineManager.removeTask(sendID: sendB, for: timelineId)
    }
}
