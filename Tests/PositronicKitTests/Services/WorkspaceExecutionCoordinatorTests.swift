import Foundation
@testable import PositronicKit
import Synchronization
import Testing

private actor ExecutionProbe {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var order: [Int] = []

    func enter(_ value: Int) {
        active += 1
        maximumActive = max(maximumActive, active)
        order.append(value)
    }

    func leave() {
        active -= 1
    }
}

/// A one-shot asynchronous gate for deterministic lane-hold tests.
private final class AsyncLatch: Sendable {
    private enum State: Sendable {
        case closed([CheckedContinuation<Void, Never>])
        case open
    }

    private let state = Mutex<State>(.closed([]))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                switch state {
                case var .closed(waiters):
                    waiters.append(continuation)
                    state = .closed(waiters)
                    return false
                case .open:
                    return true
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            switch state {
            case let .closed(waiters):
                state = .open
                return waiters
            case .open:
                return []
            }
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// `.serialized`: these scenarios interleave tasks on short sleep windows to observe
// lane ordering, so concurrent scenarios would perturb each other's timing.
@Suite("Workspace execution coordination", .serialized, .tags(.slow))
struct WorkspaceExecutionCoordinatorTests {
    @Test("Same workspace serializes FIFO without overlap")
    func sameWorkspaceIsFifoAndNonOverlapping() async throws {
        let coordinator = WorkspaceExecutionCoordinator()
        let probe = ExecutionProbe()
        let workspaceID = UUID()

        let first = Task {
            try await coordinator.withWorkspaceExecution(workspaceID: workspaceID) {
                await probe.enter(1)
                try await Task.sleep(for: .milliseconds(20))
                await probe.leave()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(2))
        let second = Task {
            try await coordinator.withWorkspaceExecution(workspaceID: workspaceID) {
                await probe.enter(2)
                await probe.leave()
                return 2
            }
        }

        let firstValue = try await first.value
        let secondValue = try await second.value
        #expect(firstValue == 1)
        #expect(secondValue == 2)
        let maximumActive = await probe.maximumActive
        let order = await probe.order
        #expect(maximumActive == 1)
        #expect(order == [1, 2])
    }

    @Test("Different workspaces execute concurrently")
    func differentWorkspacesCanExecuteConcurrently() async throws {
        let coordinator = WorkspaceExecutionCoordinator()
        let probe = ExecutionProbe()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()

        async let first: Void = coordinator.withWorkspaceExecution(workspaceID: firstWorkspace) {
            await probe.enter(1)
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        async let second: Void = coordinator.withWorkspaceExecution(workspaceID: secondWorkspace) {
            await probe.enter(2)
            try await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        _ = try await (first, second)

        let maximumActive = await probe.maximumActive
        #expect(maximumActive == 2)
    }

    @Test("A deferred hold keeps the lane closed until the abandoned task ends")
    func deferredHoldKeepsLaneClosed() async throws {
        let coordinator = WorkspaceExecutionCoordinator()
        let probe = ExecutionProbe()
        let workspaceID = UUID()
        let releaseAbandoned = AsyncLatch()

        let abandoned = Task { await releaseAbandoned.wait() }
        let first = Task {
            try await coordinator.withWorkspaceExecution(workspaceID: workspaceID) {
                await probe.enter(1)
                coordinator.hold(workspaceID, until: abandoned)
                await probe.leave()
                return 1
            }
        }
        let firstValue = try await first.value
        #expect(firstValue == 1)
        // The operation returned, but the abandoned task still owns the lane.
        #expect(coordinator.isBusy(workspaceID))

        let second = Task {
            try await coordinator.withWorkspaceExecution(workspaceID: workspaceID) {
                await probe.enter(2)
                await probe.leave()
                return 2
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.order == [1])

        releaseAbandoned.open()
        await abandoned.value
        let secondValue = try await second.value
        #expect(secondValue == 2)
        #expect(await probe.order == [1, 2])
        #expect(await probe.maximumActive == 1)
        #expect(!coordinator.isBusy(workspaceID))
    }
}
