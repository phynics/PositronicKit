import Foundation
@testable import PKContracts
@testable import PositronicKit
import PKTestSupport
import Testing

@Suite("Turn EventHub terminal subscription", .tags(.integration))
struct TurnEventHubTests {
    @Test("live subscription selection is atomic with the active check")
    func subscribeIfActiveDoesNotAttachAfterFinish() async throws {
        let hub = TurnEventHub()
        let turnID = UUID()

        await hub.begin(turnID: turnID)
        let live = await hub.subscribeIfActive(turnID: turnID)
        #expect(live != nil)

        await hub.finish(turnID: turnID)
        let afterFinish = await hub.subscribeIfActive(turnID: turnID)
        #expect(afterFinish == nil)
    }

    @Test("awaitTerminal returns unseen immediately for a Turn the hub never tracked as active")
    func awaitTerminalReturnsUnseenForUntrackedTurn() async throws {
        let hub = TurnEventHub()
        let result = await hub.awaitTerminal(turnID: UUID())
        #expect(result == .unseen)
    }

    /// A registered hub waiter must be resumed by `finish`, before the injected fallback clock
    /// advances. The runner's time limit bounds a failure that leaves the waiter suspended.
    @Test("a registered waiter wakes on finish without advancing the fallback clock", .timeLimit(.minutes(1)))
    func awaiterWakesOnFinishWithoutPolling() async throws {
        let hub = TurnEventHub()
        let turnID = UUID()
        let durableValue = DurableValueSlot()
        let clock = ManualClock()

        await hub.begin(turnID: turnID)

        let waiter = TurnTerminationWaiter(
            hub: hub,
            pollInterval: .seconds(3600),
            pollTimeout: .seconds(3600),
            clock: clock
        )
        let waiterTask = Task { () -> TurnTerminationWaiter.Observation<String> in
            try await waiter.awaitResult(turnID: turnID) {
                await durableValue.read()
            }
        }

        // `awaitTerminal` registers its continuation while isolated to the hub actor. Wait for
        // that state directly so finish cannot win the race before the waiter is actually parked.
        while await !hub.hasTerminalWaiter(turnID: turnID) {
            try Task.checkCancellation()
            await Task.yield()
        }

        await durableValue.write("durable-outcome")
        await hub.finish(turnID: turnID)

        // The time limit cancels this test, not the unstructured waiter, so forward cancellation.
        let observation = try await withTaskCancellationHandler {
            try await waiterTask.value
        } onCancel: {
            waiterTask.cancel()
        }

        guard case let .value(value) = observation else {
            Issue.record("Expected a terminal value, got \(observation)")
            return
        }
        #expect(value == "durable-outcome")
    }
}

/// Test-only mutable slot for a value written from a different task than the one reading it.
private actor DurableValueSlot {
    private var value: String?

    func write(_ newValue: String) {
        value = newValue
    }

    func read() -> String? {
        value
    }
}
