import Foundation
import PKUtilities
import Synchronization

/// Actor-owned clock for tests that need to advance time without sleeping the process.
public actor ManualClock: RuntimeClock {
    /// Raised when a caller waits for sleepers that never register, so a misuse surfaces as a
    /// failing test rather than a hung one.
    package struct SleepersNotRegistered: Error, CustomStringConvertible, Sendable {
        package let expected: Int
        package let observed: Int

        package var description: String {
            "ManualClock: expected at least \(expected) registered sleeper(s), observed \(observed)."
        }
    }

    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error> // swiftlint:disable:this concurrency_stored_continuation -- Manual clock owns and resumes each waiter exactly once (see docs/Concurrency/exception-manifest.md)
    }

    /// Held outside actor isolation so ``now()`` can satisfy `RuntimeClock`'s non-suspending
    /// requirement. Only `advance(by:)` writes it, under actor isolation.
    private let instant: Mutex<ContinuousClock.Instant>
    private var waiters: [UUID: Waiter] = [:]

    public init(start: ContinuousClock.Instant = ContinuousClock.now) {
        instant = Mutex(start)
    }

    /// Advances virtual time and resumes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        let advanced = instant.withLock { value in
            value = value.advanced(by: duration)
            return value
        }
        let ready = waiters.filter { $0.value.deadline <= advanced }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    /// Suspends until at least `count` sleepers have registered.
    ///
    /// `Task.yield()` alone is not a barrier: a test that yields once and then calls
    /// ``advance(by:)`` can win the race, leaving the sleeper to compute its deadline from the
    /// *already advanced* instant and wait forever. Await this instead, so `advance` is only
    /// ever called against sleepers that exist.
    ///
    /// - Throws: ``SleepersNotRegistered`` once `maxYields` have elapsed without the sleepers
    ///   appearing, rather than spinning indefinitely.
    package func waitForSleepers(atLeast count: Int = 1, maxYields: Int = 10_000) async throws {
        var yields = 0
        while waiters.count < count {
            guard yields < maxYields else {
                throw SleepersNotRegistered(expected: count, observed: waiters.count)
            }
            yields += 1
            await Task.yield()
        }
    }

    package nonisolated func now() -> ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    package func sleep(for duration: Duration) async throws {
        let id = UUID()
        let start = now()
        let deadline = start.advanced(by: duration)
        guard start < deadline else { return }

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
