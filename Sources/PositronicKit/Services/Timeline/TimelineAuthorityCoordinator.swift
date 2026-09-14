import Foundation

/// Process-local FIFO lanes that serialize Turn admission with Timeline authority mutations.
///
/// The lane is deliberately keyed by Timeline rather than Workspace: a Turn owns its Timeline's
/// authority context, while Workspace tool execution has its own independent per-Workspace lane.
///
/// Thin wrapper over ``FIFOLane``, which owns the cancellation-aware permit lifecycle.
final class TimelineAuthorityCoordinator: Sendable {
    private let lane = FIFOLane<UUID>()

    public init() {}

    /// Runs an operation exclusively for the Timeline, in FIFO order.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while queued, or if it is
    /// cancelled after acquiring the lane but before `operation` runs — in both cases `operation`
    /// never runs. The lane is released in either case.
    public func withTimeline<T: Sendable>(
        _ timelineID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await lane.run(timelineID, operation: operation)
    }

    public func isBusy(_ timelineID: UUID) -> Bool {
        lane.isBusy(timelineID)
    }
}
