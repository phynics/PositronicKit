import Foundation

/// Process-local FIFO lanes that serialize Turn admission with Thread authority mutations.
///
/// The lane is deliberately keyed by Thread rather than Workspace: a Turn owns its Thread's
/// authority context, while Workspace tool execution has its own independent per-Workspace lane.
actor ThreadAuthorityCoordinator {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs an operation exclusively for the Thread, in FIFO order.
    public func withThread<T: Sendable>(
        _ threadID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(threadID)
        defer { release(threadID) }
        return try await operation()
    }

    public func isBusy(_ threadID: UUID) -> Bool {
        busy.contains(threadID)
    }

    private func acquire(_ threadID: UUID) async {
        guard busy.contains(threadID) else {
            busy.insert(threadID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[threadID, default: []].append(continuation)
        }
    }

    private func release(_ threadID: UUID) {
        guard var queued = waiters[threadID], !queued.isEmpty else {
            busy.remove(threadID)
            waiters.removeValue(forKey: threadID)
            return
        }
        let next = queued.removeFirst()
        waiters[threadID] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
