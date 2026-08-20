import Foundation

/// Process-local FIFO lanes that serialize Agent lifecycle changes with managed Turn
/// admission.  The lane is keyed by Agent identity so an update or retirement cannot commit
/// between capturing an authoritative context snapshot and admitting the next Turn.
actor AgentAuthorityCoordinator {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs an operation exclusively for the Agent, in FIFO order.
    public func withAgent<T: Sendable>(
        _ agentID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(agentID)
        defer { release(agentID) }
        return try await operation()
    }

    public func isBusy(_ agentID: UUID) -> Bool {
        busy.contains(agentID)
    }

    private func acquire(_ agentID: UUID) async {
        guard busy.contains(agentID) else {
            busy.insert(agentID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[agentID, default: []].append(continuation)
        }
    }

    private func release(_ agentID: UUID) {
        guard var queued = waiters[agentID], !queued.isEmpty else {
            busy.remove(agentID)
            waiters.removeValue(forKey: agentID)
            return
        }
        let next = queued.removeFirst()
        waiters[agentID] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
