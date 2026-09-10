import Foundation

/// Package-internal clock used by runtime timing policies.
package protocol RuntimeClock: Sendable {
    func now() async -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

package struct ContinuousRuntimeClock: RuntimeClock, Sendable {
    private let clock: ContinuousClock

    package init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }

    package func now() async -> ContinuousClock.Instant {
        clock.now
    }

    package func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
