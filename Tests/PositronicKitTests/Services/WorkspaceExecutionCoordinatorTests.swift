import Foundation
@testable import PositronicKit
import XCTest

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

final class WorkspaceExecutionCoordinatorTests: XCTestCase {
    func testSameWorkspaceIsFifoAndNonOverlapping() async throws {
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
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        let maximumActive = await probe.maximumActive
        let order = await probe.order
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(order, [1, 2])
    }

    func testDifferentWorkspacesCanExecuteConcurrently() async throws {
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
        XCTAssertEqual(maximumActive, 2)
    }
}
