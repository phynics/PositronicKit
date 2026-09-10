import Foundation
import PKUtilities

/// Actor-owned clock for tests that need to advance time without sleeping the process.
public actor ManualClock: RuntimeClock {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error> // swiftlint:disable:this concurrency_stored_continuation -- Manual clock owns and resumes each waiter exactly once (see docs/Concurrency/exception-manifest.md)
    }

    private var instant: ContinuousClock.Instant
    private var waiters: [UUID: Waiter] = [:]

    public init(start: ContinuousClock.Instant = ContinuousClock.now) {
        instant = start
    }

    /// Advances virtual time and resumes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        let ready = waiters.filter { $0.value.deadline <= instant }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    package func now() async -> ContinuousClock.Instant {
        instant
    }

    package func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = instant.advanced(by: duration)
        guard instant < deadline else { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: id) }
        }
    }

    private func cancel(waiterID id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
