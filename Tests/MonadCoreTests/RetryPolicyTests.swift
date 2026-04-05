import Testing
import Synchronization
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite("Retry Policy Tests")
struct RetryPolicyTests {

    @Test("Succeeds on first attempt")
    func testSuccessOnFirstAttempt() async throws {
        let result = try await RetryPolicy.retry(maxRetries: 3) {
            return "Success"
        }
        #expect(result == "Success")
    }

    @Test("Succeeds after transient failures")
    func testSuccessAfterRetries() async throws {
        let attempts = Mutex(0)
        let result = try await RetryPolicy.retry(maxRetries: 3, baseDelay: 0.001) {
            attempts.withLock { $0 += 1 }
            let currentAttempts = attempts.withLock { $0 }
            if currentAttempts <= 2 {
                throw URLError(.timedOut) // Simulate timeout twice
            }
            return "Success"
        }
        #expect(result == "Success")
        let finalAttempts = attempts.withLock { $0 }
        #expect(finalAttempts == 3) // 1st try (fail), 2nd try (fail), 3rd try (success)
    }

    @Test("Fails after max retries exhausted")
    func testFailsAfterMaxRetries() async throws {
        let attempts = Mutex(0)
        await #expect(throws: URLError.self) {
            try await RetryPolicy.retry(maxRetries: 2, baseDelay: 0.001) {
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        // maxRetries = 2
        // 1st attempt (fail) -> attempts=1. Check: 0 >= 2 false. Retry 1.
        // 2nd attempt (fail) -> attempts=2. Check: 1 >= 2 false. Retry 2.
        // 3rd attempt (fail) -> attempts=3. Check: 2 >= 2 true. Throw.
        let finalAttempts = attempts.withLock { $0 }
        #expect(finalAttempts == 3)
    }

    @Test("Fails immediately on non-transient error")
    func testFailsImmediately() async throws {
        struct FatalError: Error {}

        let attempts = Mutex(0)

        await #expect(throws: FatalError.self) {
            try await RetryPolicy.retry(
                maxRetries: 3,
                baseDelay: 0.001,
                shouldRetry: { error in
                    // Default logic might not cover custom FatalError,
                    // so we explicitly use default logic which returns false for unknown errors
                    return RetryPolicy.isTransient(error: error)
                }
            ) {
                attempts.withLock { $0 += 1 }
                throw FatalError()
            }
        }
        let finalAttempts = attempts.withLock { $0 }
        #expect(finalAttempts == 1)
    }
}
