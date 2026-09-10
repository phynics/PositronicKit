import Foundation
import Testing
import PKTestSupport

@Suite("Manual clock")
struct ManualClockTests {
    @Test("advancing virtual time resumes due sleepers", .timeLimit(.minutes(1)))
    func advancingVirtualTimeResumesDueSleepers() async throws {
        let clock = ManualClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(5))
        }

        // Wait for registration rather than yielding once: if `advance` won that race the
        // sleeper would compute its deadline from the advanced instant and never wake.
        try await clock.waitForSleepers()
        #expect(!sleeper.isCancelled)
        await clock.advance(by: .seconds(5))
        try await sleeper.value
    }
}
