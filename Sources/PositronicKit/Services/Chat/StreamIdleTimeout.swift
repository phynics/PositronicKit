import Foundation

/// Runs a stream operation alongside the shared per-stream inactivity watchdog.
package enum StreamIdleTimeout {
    package static func run<Value: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable (StreamIdleDeadline) async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = StreamIdleDeadline(timeout: timeout, clock: clock)

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation(deadline)
            }
            group.addTask {
                while true {
                    let remaining = await deadline.remaining()
                    if remaining <= .zero {
                        throw ChatEngineError.streamTimedOut(timeout)
                    }
                    try await Task.sleep(for: remaining, clock: clock)
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
    private let clock: ContinuousClock
    private var deadline: ContinuousClock.Instant

    init(timeout: TimeInterval, clock: ContinuousClock) {
        self.timeout = timeout
        self.clock = clock
        deadline = clock.now.advanced(by: .seconds(timeout))
    }

    func reset() {
        deadline = clock.now.advanced(by: .seconds(timeout))
    }

    func remaining() -> Duration {
        deadline - clock.now
    }
}
