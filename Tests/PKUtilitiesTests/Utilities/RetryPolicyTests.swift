import Foundation
import Synchronization
import Testing
@testable import PKUtilities

@Suite("RetryPolicy total elapsed budget")
struct RetryPolicyTests {

    @Test("Clamps a planned delay to the remaining total elapsed budget")
    func plannedDelayIsClampedToRemainingBudget() async throws {
        let elapsed = Mutex(TimeInterval(0))
        let sleepDelays = Mutex([TimeInterval]())
        let attempts = Mutex(0)
        let configuration = try RetryConfiguration(
            maxRetries: 3,
            baseDelay: 10,
            maxDelay: 10,
            maxTotalElapsedTime: 5,
            jitter: .none
        )

        await #expect(throws: URLError.self) {
            _ = try await RetryPolicy.retry(
                configuration: configuration,
                shouldRetry: { _ in true },
                loggingConfiguration: .default,
                elapsedTime: { elapsed.withLock { $0 } },
                sleeper: { delay in
                    sleepDelays.withLock { $0.append(delay) }
                    elapsed.withLock { $0 += delay }
                }
            ) {
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }

        #expect(attempts.withLock { $0 } == 2)
        #expect(sleepDelays.withLock { $0 } == [5])
    }
}
