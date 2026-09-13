import Foundation
@testable import PKContracts
@testable import PositronicKit
import Testing

@Suite("Turn EventHub terminal subscription")
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

    /// This is the deterministic proof for finding B-01: a waiter suspended in
    /// `awaitTerminal(turnID:)` is woken directly by `finish(turnID:)`, not by a poll tick.
    ///
    /// The poll interval and timeout are configured to be enormous (far longer than the whole
    /// test suite's budget). If the wake path silently fell back to polling — the exact defect
    /// this change removes — this test would hang for that duration instead of completing in
    /// milliseconds, so it would fail on timeout rather than pass by coincidence.
    @Test("a waiter suspended in awaitTerminal wakes on finish(), not on a poll tick")
    func awaiterWakesOnFinishWithoutPolling() async throws {
        let hub = TurnEventHub()
        let turnID = UUID()
        let durableValue = DurableValueSlot()

        await hub.begin(turnID: turnID)

        let waiter = TurnTerminationWaiter(hub: hub, pollInterval: .seconds(3600), pollTimeout: .seconds(3600))
        let waiterTask = Task { () -> TurnTerminationWaiter.Observation<String> in
            try await waiter.awaitResult(turnID: turnID) {
                await durableValue.read()
            }
        }

        // Give the waiter task room to reach and register inside `awaitTerminal` before this
        // finishes the Turn. This is a scheduling settle pause, not a correctness dependency: the
        // assertion below only holds if the wake is push-driven, since the configured poll
        // interval (one hour) makes the fallback path unobservably slow in comparison.
        try await Task.sleep(for: .milliseconds(20))

        let clock = ContinuousClock()
        let start = clock.now
        await durableValue.write("durable-outcome")
        await hub.finish(turnID: turnID)

        let observation = try await waiterTask.value
        let elapsed = clock.now - start

        guard case let .value(value) = observation else {
            Issue.record("Expected a terminal value, got \(observation)")
            return
        }
        #expect(value == "durable-outcome")
        #expect(elapsed < .seconds(2))
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
