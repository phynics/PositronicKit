import Foundation
@testable import PositronicKit
import Testing

private actor AgentExecutionProbe {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var events: [Int] = []
    private var started = false
    private var released = false

    func enter(_ value: Int) {
        active += 1
        maximumActive = max(maximumActive, active)
        events.append(value)
        started = true
    }

    func leave() {
        active -= 1
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func waitUntilReleased() async {
        while !released {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }
}

// `.serialized`: these scenarios interleave tasks on short sleep windows to observe
// lane ordering, so concurrent scenarios would perturb each other's timing.
@Suite("Agent authority coordination", .serialized, .tags(.slow))
struct AgentAuthorityCoordinatorTests {
    @Test("Same agent serializes FIFO without overlap")
    func sameAgentIsFifoAndNonOverlapping() async throws {
        let coordinator = AgentAuthorityCoordinator()
        let probe = AgentExecutionProbe()
        let agentID = UUID()

        let first = Task {
            try await coordinator.withAgent(agentID) {
                await probe.enter(1)
                await probe.waitUntilReleased()
                await probe.leave()
                return 1
            }
        }
        await probe.waitUntilStarted()

        let second = Task {
            try await coordinator.withAgent(agentID) {
                await probe.enter(2)
                await probe.leave()
                return 2
            }
        }

        try await Task.sleep(for: .milliseconds(5))
        await probe.release()

        let firstValue = try await first.value
        let secondValue = try await second.value
        let maximumActive = await probe.maximumActive
        let events = await probe.events
        #expect(firstValue == 1)
        #expect(secondValue == 2)
        #expect(maximumActive == 1)
        #expect(events == [1, 2])
    }

    @Test("Different agents execute concurrently")
    func differentAgentsCanExecuteConcurrently() async throws {
        let coordinator = AgentAuthorityCoordinator()
        let probe = AgentExecutionProbe()

        async let first: Void = coordinator.withAgent(UUID()) {
            await probe.enter(1)
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        async let second: Void = coordinator.withAgent(UUID()) {
            await probe.enter(2)
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        _ = try await (first, second)

        let maximumActive = await probe.maximumActive
        #expect(maximumActive == 2)
    }

    @Test("Cancelled waiter does not run after the lane is released")
    func cancelledWaiterDoesNotRunAfterTheLaneIsReleased() async throws {
        let coordinator = AgentAuthorityCoordinator()
        let probe = AgentExecutionProbe()
        let agentID = UUID()

        let first = Task {
            try await coordinator.withAgent(agentID) {
                await probe.enter(1)
                await probe.waitUntilReleased()
                await probe.leave()
            }
        }
        await probe.waitUntilStarted()

        let cancelled = Task {
            do {
                try await coordinator.withAgent(agentID) {
                    await probe.enter(2)
                    await probe.leave()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        try await Task.sleep(for: .milliseconds(5))
        cancelled.cancel()
        let didCancel = await cancelled.value
        #expect(didCancel)

        await probe.release()
        try await first.value

        try await coordinator.withAgent(agentID) {
            await probe.enter(3)
            await probe.leave()
        }

        let events = await probe.events
        let isBusy = coordinator.isBusy(agentID)
        #expect(events == [1, 3])
        #expect(!isBusy)
    }
}
