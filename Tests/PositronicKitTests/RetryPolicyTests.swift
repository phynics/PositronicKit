import Testing
import Synchronization
@testable import PositronicKit
@testable import PKShared
import PKUtilities
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

    @Test("HTTP status retry classification matches provider policy")
    func httpStatusRetryClassification() {
        #expect(RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 408, responseBody: "", retryAfter: nil)))
        #expect(RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 429, responseBody: "", retryAfter: 2)))
        #expect(RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 500, responseBody: "", retryAfter: nil)))
        #expect(!RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 400, responseBody: "", retryAfter: nil)))
        #expect(!RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 401, responseBody: "", retryAfter: nil)))
        #expect(!RetryPolicy.isTransient(error: LLMServiceError.httpError(provider: "test", statusCode: 403, responseBody: "", retryAfter: nil)))
    }

    @Test("Retry-After delay overrides exponential backoff")
    func retryAfterOverridesDelay() async throws {
        let attempts = Mutex(0)
        let started = ContinuousClock.now

        let result = try await RetryPolicy.retry(maxRetries: 2, baseDelay: 0.001) {
            attempts.withLock { $0 += 1 }
            if attempts.withLock({ $0 }) == 1 {
                throw LLMServiceError.httpError(provider: "test", statusCode: 429, responseBody: "rate limited", retryAfter: 0.05)
            }
            return "ok"
        }

        #expect(result == "ok")
        #expect(attempts.withLock { $0 } == 2)
        #expect(started.duration(to: .now) >= .milliseconds(45))
    }

    @Test("Cancellation is preserved without retries")
    func cancellationDoesNotRetry() async throws {
        let attempts = Mutex(0)

        await #expect(throws: CancellationError.self) {
            try await RetryPolicy.retry(maxRetries: 3, baseDelay: 0.001) {
                attempts.withLock { $0 += 1 }
                throw CancellationError()
            }
        }

        #expect(attempts.withLock { $0 } == 1)
    }

    // MARK: - PKR-5: Duplicate-content retry gate integration

    @Test("Retry gate blocks retry after content was yielded (matches provider shouldRetry gate)")
    func retryGateBlocksAfterYield() async throws {
        // Mirrors the exact gate every provider uses:
        //   shouldRetry: { recoveryState.shouldRetryAfterError && RetryPolicy.isTransient(error:) }
        // After content is yielded, shouldRetryAfterError flips to false → the transient error
        // propagates without a retry attempt.
        let recoveryState = Mutex(LLMToolCallRecoveryState())
        let attempts = Mutex(0)

        await #expect(throws: URLError.self) {
            try await RetryPolicy.retry(
                maxRetries: 3,
                baseDelay: 0.001,
                shouldRetry: { error in
                    recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: error)
                },
                operation: {
                    attempts.withLock { $0 += 1 }
                    // Simulate: yield content, then throw a transient error on the next iteration.
                    if attempts.withLock({ $0 }) == 1 {
                        recoveryState.withLock { $0.observe(yieldedContent: true, streamedToolCalls: false, finishedWithToolCalls: false) }
                        throw URLError(.timedOut)
                    }
                    return "should-not-reach"
                }
            )
        }

        #expect(attempts.withLock { $0 } == 1, "Gate must block retry after content was yielded")
    }

    @Test("Retry gate allows retry when no content was yielded yet")
    func retryGateAllowsBeforeYield() async throws {
        let recoveryState = Mutex(LLMToolCallRecoveryState())
        let attempts = Mutex(0)

        let result = try await RetryPolicy.retry(
            maxRetries: 3,
            baseDelay: 0.001,
            shouldRetry: { error in
                recoveryState.withLock { $0.shouldRetryAfterError } && RetryPolicy.isTransient(error: error)
            },
            operation: {
                attempts.withLock { $0 += 1 }
                if attempts.withLock({ $0 }) == 1 {
                    // No content yielded — gate returns true → retry proceeds.
                    throw URLError(.timedOut)
                }
                return "recovered"
            }
        )

        #expect(result == "recovered")
        #expect(attempts.withLock { $0 } == 2)
    }
}
