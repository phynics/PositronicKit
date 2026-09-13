import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("Runtime timing seams")
struct TimingSeamTests {
    @Test("Stream idle timeout fires at the manually advanced deadline", .timeLimit(.minutes(1)))
    func streamIdleTimeoutUsesInjectedClock() async throws {
        let clock = ManualClock()
        let neverFinishing = AsyncStream<Void> { _ in }
        let timeoutTask = Task {
            try await StreamIdleTimeout.run(timeout: 5, clock: clock) { _ in
                for await _ in neverFinishing { }
            }
        }

        // `StreamIdleTimeout.run` samples its start instant inside the task, so advancing
        // before the watchdog registers would set the deadline past the new "now".
        try await clock.waitForSleepers()
        await clock.advance(by: .seconds(5))

        await #expect(throws: TurnEngineError.self) {
            try await timeoutTask.value
        }
    }
}
