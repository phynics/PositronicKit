import Foundation
@testable import PositronicKit
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
}
