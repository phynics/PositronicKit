import Foundation
import PKUtilities

/// Runs a stream operation alongside the shared per-stream inactivity watchdog.
package enum StreamIdleTimeout {
    package static func run<Value: Sendable>(
        timeout: TimeInterval,
        clock: any RuntimeClock = ContinuousRuntimeClock(),
        operation: @escaping @Sendable (StreamIdleDeadline) async throws -> Value
    ) async throws -> Value {
        let deadline = StreamIdleDeadline(timeout: timeout, clock: clock, start: clock.now())

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation(deadline)
            }
            group.addTask {
                while true {
                    let remaining = await deadline.remaining()
                    if remaining <= .zero {
                        throw TurnEngineError.streamTimedOut(timeout)
                    }
                    try await clock.sleep(for: remaining)
                }
            }

            guard let value = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return value
        }
    }
}

package actor StreamIdleDeadline {
    private let timeout: TimeInterval
    private let clock: any RuntimeClock
    private var deadline: ContinuousClock.Instant

    init(timeout: TimeInterval, clock: any RuntimeClock, start: ContinuousClock.Instant) {
        self.timeout = timeout
        self.clock = clock
        deadline = start.advanced(by: .seconds(timeout))
    }

    /// Non-suspending by construction: the clock read and the deadline write happen in one
    /// actor step, so a concurrent ``remaining()`` cannot observe a half-applied reset.
    func reset() {
        deadline = clock.now().advanced(by: .seconds(timeout))
    }

    func remaining() -> Duration {
        deadline - clock.now()
    }
}
