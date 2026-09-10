import Foundation
import Testing
import PKTestSupport

@Suite("Manual clock")
struct ManualClockTests {
    @Test("advancing virtual time resumes due sleepers")
    func advancingVirtualTimeResumesDueSleepers() async throws {
        let clock = ManualClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(5))
        }

        await Task.yield()
        #expect(!sleeper.isCancelled)
        await clock.advance(by: .seconds(5))
        try await sleeper.value
    }
}
