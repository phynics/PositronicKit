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

    /// Whether a Workspace currently has an executing or queued operation.
    public func isBusy(_ workspaceID: UUID) -> Bool {
        lane.isBusy(workspaceID)
    }
}
