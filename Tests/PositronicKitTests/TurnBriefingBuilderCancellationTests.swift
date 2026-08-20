import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

@Suite(.serialized) struct TurnBriefingBuilderCancellationTests {
    private func makeTurnBriefingBuilder() async throws -> TurnBriefingBuilder {
        TurnBriefingBuilder(workspace: nil)
    }

    @Test("gatherContext emits at least one progress event before completing")
    func gatherContext_emitsEvents() async throws {
        let manager = try await makeTurnBriefingBuilder()
        let stream = await manager.gatherContext(for: "test query")

        var events: [ContextGatheringEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(!events.isEmpty, "Should emit at least one event")
        // Last event should be .complete
        if let last = events.last {
            if case .complete = last { /* expected */ } else { Issue.record("Last event should be .complete, got \(last)") }
        }
    }

    @Test("gatherContext can be cancelled without hanging")
    func gatherContext_cancellation_doesNotHang() async throws {
        let manager = try await makeTurnBriefingBuilder()

        // Deterministic checkpoint: flipped as soon as the stream emits its first event,
        // so cancellation is triggered mid-stream rather than after a guessed sleep duration.
        let sawFirstEvent = Mutex(false)

        let streamTask = Task {
            let stream = await manager.gatherContext(for: "test query for cancellation")
            var count = 0
            for try await _ in stream {
                count += 1
                sawFirstEvent.withLock { $0 = true }
            }
            return count
        }

        // Poll until the first event is observed, with a generous CI-safe upper bound
        // (real-time is unavoidable here since we're synchronizing across a Task boundary,
        // but the bound only guards against a genuine hang, not normal scheduling variance).
        let deadline = ContinuousClock.now + .seconds(5)
        while !sawFirstEvent.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }

        streamTask.cancel()

        // The task should resolve (either completed or cancelled) without hanging
        _ = await streamTask.result
        // If we reach here, cancellation didn't deadlock
    }

    @Test("gatherContext with empty query produces complete event")
    func gatherContext_emptyQuery_completesSuccessfully() async throws {
        let manager = try await makeTurnBriefingBuilder()
        let stream = await manager.gatherContext(for: "")

        var sawComplete = false
        for try await event in stream {
            if case .complete = event {
                sawComplete = true
            }
        }
        #expect(sawComplete)
    }

    @Test("Multiple sequential gatherContext calls complete successfully")
    func gatherContext_sequentialCalls_allComplete() async throws {
        let manager = try await makeTurnBriefingBuilder()

        for index in 1 ... 3 {
            let stream = await manager.gatherContext(for: "query number \(index)")
            var sawComplete = false
            for try await event in stream {
                if case .complete = event { sawComplete = true }
            }
            #expect(sawComplete, "Call \(index) should complete")
        }
    }
}
