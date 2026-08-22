import Foundation
import Synchronization

/// Process-local FIFO lanes that serialize Agent lifecycle changes with managed Turn
/// admission.  The lane is keyed by Agent identity so an update or retirement cannot commit
/// between capturing an authoritative context snapshot and admitting the next Turn.
final class AgentAuthorityCoordinator: Sendable {
    private enum Acquisition: Sendable {
        case acquired
        case waiting
        case cancelled
    }

    /// A cancellation-aware permit with an explicit lifecycle.
    ///
    /// The coordinator owns FIFO ordering, while this state machine owns the race between
    /// installing a continuation, granting the permit, and cancelling the waiting task. This
    /// lets cancellation resume the suspended task immediately without asking an unstructured
    /// task to call back into the coordinator.
    private final class PermitWaiter: Sendable {
        private enum Phase: Sendable {
            case pending
            case granted
            case cancelled
        }

        private struct State: Sendable {
            var phase: Phase = .pending
            var continuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- mutex-owned permit lifecycle (see docs/Concurrency/exception-manifest.md)
        }

        private let state = Mutex(State())

        var isCancelled: Bool {
            state.withLock { $0.phase == .cancelled }
        }

        var wasGranted: Bool {
            state.withLock { $0.phase == .granted }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately = state.withLock { state in
                    guard state.phase == .pending else {
                        return true
                    }
                    state.continuation = continuation
                    return false
                }

                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        func cancel() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard state.phase == .pending else {
                    return nil
                }
                state.phase = .cancelled
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }

        /// Marks the permit as granted and resumes the waiter if it has installed its
        /// continuation already. If installation happens later, `wait()` observes the granted
        /// phase and resumes itself.
        func grant() -> Bool {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard state.phase == .pending else {
                    return nil
                }
                state.phase = .granted
                defer { state.continuation = nil }
                return state.continuation
            }

            continuation?.resume()
            return wasGranted
        }
    }

    private struct CoordinatorState: Sendable {
        var busy: Set<UUID> = []
        var waiters: [UUID: [PermitWaiter]] = [:]
    }

    private let state = Mutex(CoordinatorState())

    public init() {}

    /// Runs an operation exclusively for the Agent, in FIFO order.
    public func withAgent<T: Sendable>(
        _ agentID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let waiter = PermitWaiter()
        let acquired = await withTaskCancellationHandler(operation: {
            switch acquire(agentID, waiter: waiter) {
            case .acquired:
                return true
            case .cancelled:
                return false
            case .waiting:
                await waiter.wait()
                return waiter.wasGranted
            }
        }, onCancel: {
            cancel(agentID, waiter: waiter)
        })

        guard acquired else {
            throw CancellationError()
        }

        defer { release(agentID) }
        try Task.checkCancellation()
        return try await operation()
    }

    public func isBusy(_ agentID: UUID) -> Bool {
        state.withLock { $0.busy.contains(agentID) }
    }

    private func acquire(_ agentID: UUID, waiter: PermitWaiter) -> Acquisition {
        state.withLock { state in
            guard state.busy.contains(agentID) else {
                state.busy.insert(agentID)
                return .acquired
            }

            guard !waiter.isCancelled else {
                return .cancelled
            }

            state.waiters[agentID, default: []].append(waiter)
            return .waiting
        }
    }

    private func cancel(_ agentID: UUID, waiter: PermitWaiter) {
        waiter.cancel()
        state.withLock { state in
            guard var queued = state.waiters[agentID] else {
                return
            }
            queued.removeAll { $0 === waiter }
            state.waiters[agentID] = queued.isEmpty ? nil : queued
        }
    }

    private func release(_ agentID: UUID) {
        while let next = state.withLock({ state -> PermitWaiter? in
            guard state.busy.contains(agentID) else {
                return nil
            }

            guard var queued = state.waiters[agentID], !queued.isEmpty else {
                state.busy.remove(agentID)
                state.waiters.removeValue(forKey: agentID)
                return nil
            }

            let next = queued.removeFirst()
            state.waiters[agentID] = queued.isEmpty ? nil : queued
            return next
        }) {
            if next.grant() {
                return
            }
        }
    }
}
