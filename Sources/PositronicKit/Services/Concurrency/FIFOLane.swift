import Foundation
import Synchronization

/// A process-local, cancellation-aware FIFO execution lane keyed by `Key`.
///
/// `FIFOLane` is the single implementation backing every "run exclusively for this identity, in
/// arrival order" coordinator in the runtime (Agent lifecycle, Thread authority, Workspace
/// execution). Calls that share a key never overlap and preserve arrival order; calls with
/// different keys may run concurrently. A caller whose task is cancelled while queued is removed
/// from the lane and never runs its operation — ``run(_:operation:)`` throws `CancellationError`
/// instead.
///
/// The lane owns FIFO ordering via a `Synchronization.Mutex`-protected state dictionary. Each
/// queued waiter owns the race between installing its continuation, being granted the lane, and
/// being cancelled through a separate mutex-protected ``PermitWaiter`` state machine, so
/// cancellation can resume the suspended task synchronously without an unstructured cleanup task.
final class FIFOLane<Key: Hashable & Sendable>: Sendable {
    private enum Acquisition: Sendable {
        case acquired
        case waiting
        case cancelled
    }

    /// A cancellation-aware permit with an explicit lifecycle.
    ///
    /// The lane owns FIFO ordering, while this state machine owns the race between installing a
    /// continuation, granting the permit, and cancelling the waiting task. This lets cancellation
    /// resume the suspended task immediately without asking an unstructured task to call back
    /// into the lane.
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

    private struct LaneState: Sendable {
        var busy: Set<Key> = []
        var waiters: [Key: [PermitWaiter]] = [:]
    }

    private let state = Mutex(LaneState())

    init() {}

    /// Runs `operation` exclusively for `key`, in FIFO order.
    ///
    /// If the calling task is cancelled while queued, the waiter is removed from the lane and
    /// this throws `CancellationError` without ever invoking `operation`. If the task is
    /// cancelled after being granted the lane but before `operation` starts, this throws
    /// `CancellationError` too (checked once, after acquisition) — the lane is still released.
    func run<T: Sendable>(
        _ key: Key,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let waiter = PermitWaiter()
        let acquired = await withTaskCancellationHandler(operation: {
            switch acquire(key, waiter: waiter) {
            case .acquired:
                return true
            case .cancelled:
                return false
            case .waiting:
                await waiter.wait()
                return waiter.wasGranted
            }
        }, onCancel: {
            cancel(key, waiter: waiter)
        })

        guard acquired else {
            throw CancellationError()
        }

        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    func isBusy(_ key: Key) -> Bool {
        state.withLock { $0.busy.contains(key) }
    }

    private func acquire(_ key: Key, waiter: PermitWaiter) -> Acquisition {
        state.withLock { state in
            guard state.busy.contains(key) else {
                state.busy.insert(key)
                return .acquired
            }

            guard !waiter.isCancelled else {
                return .cancelled
            }

            state.waiters[key, default: []].append(waiter)
            return .waiting
        }
    }

    private func cancel(_ key: Key, waiter: PermitWaiter) {
        waiter.cancel()
        state.withLock { state in
            guard var queued = state.waiters[key] else {
                return
            }
            queued.removeAll { $0 === waiter }
            state.waiters[key] = queued.isEmpty ? nil : queued
        }
    }

    private func release(_ key: Key) {
        while let next = state.withLock({ state -> PermitWaiter? in
            guard state.busy.contains(key) else {
                return nil
            }

            guard var queued = state.waiters[key], !queued.isEmpty else {
                state.busy.remove(key)
                state.waiters.removeValue(forKey: key)
                return nil
            }

            let next = queued.removeFirst()
            state.waiters[key] = queued.isEmpty ? nil : queued
            return next
        }) {
            if next.grant() {
                return
            }
        }
    }
}
