import Foundation

/// Process-local FIFO lanes that serialize Agent lifecycle changes with managed Turn
/// admission.  The lane is keyed by Agent identity so an update or retirement cannot commit
/// between capturing an authoritative context snapshot and admitting the next Turn.
///
/// Thin wrapper over ``FIFOLane``, which owns the cancellation-aware permit lifecycle.
final class AgentAuthorityCoordinator: Sendable {
    private let lane = FIFOLane<UUID>()

    public init() {}

    /// Runs an operation exclusively for the Agent, in FIFO order.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while queued, or if it is
    /// cancelled after acquiring the lane but before `operation` runs. The lane is released in
    /// either case.
    public func withAgent<T: Sendable>(
        _ agentID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await lane.run(agentID, operation: operation)
    }

    public func isBusy(_ agentID: UUID) -> Bool {
        lane.isBusy(agentID)
    }
}
