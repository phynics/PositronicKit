import Foundation

/// Package-internal clock used by runtime timing policies.
///
/// `now()` is deliberately non-suspending. `StreamIdleDeadline` reads and writes its deadline
/// from inside an actor, and a suspension point between sampling the clock and touching the
/// deadline would let a watchdog read interleave with a chunk's reset — producing a spurious
/// idle timeout. Implementations must therefore expose the current instant synchronously.
package protocol RuntimeClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

package struct ContinuousRuntimeClock: RuntimeClock, Sendable {
    private let clock: ContinuousClock

    package init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }

    package func now() -> ContinuousClock.Instant {
        clock.now
    }

    package func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
