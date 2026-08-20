import Foundation

/// Process-local FIFO execution lanes keyed by ordinary Workspace identity.
///
/// Calls for one Workspace do not overlap and retain arrival order. Different Workspaces use
/// independent lanes and may execute concurrently. Multi-process hosts must provide stronger
/// coordination in their persistence/execution backend; this actor only owns local ordering.
public actor WorkspaceExecutionCoordinator {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs an operation after acquiring the Workspace's FIFO lane.
    public func withWorkspace<T: Sendable>(
        _ workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(workspaceID)
        do {
            let result = try await operation()
            release(workspaceID)
            return result
        } catch {
            release(workspaceID)
            throw error
        }
    }

    public func withWorkspace<T: Sendable>(
        id workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        try await withWorkspace(workspaceID, operation: operation)
    }

    public func withWorkspaceExecution<T: Sendable>(
        workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        try await withWorkspace(workspaceID, operation: operation)
    }

    /// Acquires a lane for callers that need to span multiple operations. Pair with
    /// ``release(_:)`` in the same task.
    public func acquire(_ workspaceID: UUID) async {
        guard busy.contains(workspaceID) else {
            busy.insert(workspaceID)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[workspaceID, default: []].append(continuation)
        }
    }

    /// Releases a lane and wakes the oldest waiter, if any.
    public func release(_ workspaceID: UUID) {
        guard busy.contains(workspaceID) else { return }
        if var queued = waiters[workspaceID], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[workspaceID] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            busy.remove(workspaceID)
        }
    }

    /// Whether a Workspace currently has an executing or queued operation.
    public func isBusy(_ workspaceID: UUID) -> Bool {
        busy.contains(workspaceID)
    }
}
