import Foundation

/// Process-local FIFO lanes that serialize Turn admission with Thread authority mutations.
///
/// The lane is deliberately keyed by Thread rather than Workspace: a Turn owns its Thread's
/// authority context, while Workspace tool execution has its own independent per-Workspace lane.
///
/// Thin wrapper over ``FIFOLane``, which owns the cancellation-aware permit lifecycle.
final class ThreadAuthorityCoordinator: Sendable {
    private let lane = FIFOLane<UUID>()

    public init() {}

    /// Runs an operation exclusively for the Thread, in FIFO order.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while queued, or if it is
    /// cancelled after acquiring the lane but before `operation` runs — in both cases `operation`
    /// never runs. The lane is released in either case.
    public func withThread<T: Sendable>(
        _ threadID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await lane.run(threadID, operation: operation)
    }

    public func isBusy(_ threadID: UUID) -> Bool {
        lane.isBusy(threadID)
    }
}
