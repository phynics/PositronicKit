import Foundation

/// Process-local FIFO execution lanes keyed by ordinary Workspace identity.
///
/// Calls for one Workspace do not overlap and retain arrival order. Different Workspaces use
/// independent lanes and may execute concurrently. Multi-process hosts must provide stronger
/// coordination in their persistence/execution backend; this coordinator only owns local
/// ordering.
///
/// Thin wrapper over ``FIFOLane``, which owns the cancellation-aware permit lifecycle.
final class WorkspaceExecutionCoordinator: Sendable {
    private let lane = FIFOLane<UUID>()

    public init() {}

    /// Runs `operation` after acquiring the Workspace's FIFO lane.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while queued, or if it is
    /// cancelled after acquiring the lane but before `operation` runs — in both cases `operation`
    /// never runs. The lane is released in either case.
    public func withWorkspaceExecution<T: Sendable>(
        workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await lane.run(workspaceID, operation: operation)
    }

    /// Whether a Workspace currently has an executing, queued, or deferred operation.
    public func isBusy(_ workspaceID: UUID) -> Bool {
        lane.isBusy(workspaceID)
    }

    /// Keeps the Workspace lane closed until `task` completes.
    ///
    /// The Workspace Execution Lane calls this when a mutating or external-process tool times
    /// out and is abandoned but may still be running. The lane then stays closed after the
    /// timed-out operation returns, so the next call for the Workspace cannot overlap the
    /// abandoned tool. Must be called from the operation that currently holds the lane.
    public func hold(_ workspaceID: UUID, until task: Task<Void, Never>) {
        lane.hold(workspaceID, until: task)
    }
}
