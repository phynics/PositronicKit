import Foundation
import Synchronization
import Testing
@testable import PKShared
import PKUtilities

/// Regression tests for PKRR-030: `RetryPolicy.retry` must reject invalid numeric
/// values (negative, NaN, infinite, extreme) with typed errors rather than silently
/// producing bad behavior (immediate loops, excessive sleeps, or `UInt64` conversion
/// traps). Server `Retry-After` hints are capped by host policy. Both attempt and
/// total-elapsed limits are enforced.
///
/// These tests also serve as the "reproduce the current accept-anything behavior
/// before the fix" regression guard required by the acceptance criteria: before
/// PKRR-030, `retry(maxRetries: -1, baseDelay: .nan)` was silently accepted and
/// would trap or loop; now it throws `RetryConfigurationError`.
@Suite("RetryPolicy validation and budgets (PKRR-030)")
struct RetryPolicyValidationTests {

    // MARK: - Invalid values fail with typed errors (regression guards)

    @Test("Negative maxRetries throws RetryConfigurationError")
    func negativeMaxRetriesRejected() async throws {
        await #expect(throws: RetryConfigurationError.self) {
            _ = try await RetryPolicy.retry(maxRetries: -1, baseDelay: 0.001) { "ok" }
        }
    }

    @Test("NaN baseDelay throws RetryConfigurationError instead of trapping")
    func nanBaseDelayRejected() async throws {
        // Before PKRR-030: Double.random(in: 0.0 ... (NaN * 0.1)) would trap.
        await #expect(throws: RetryConfigurationError.self) {
            _ = try await RetryPolicy.retry(maxRetries: 1, baseDelay: .nan) { "ok" }
        }
    }

    @Test("Infinite baseDelay throws RetryConfigurationError instead of trapping")
    func infiniteBaseDelayRejected() async throws {
        // Before PKRR-030: UInt64(infinity * 1_000_000_000) would trap.
        await #expect(throws: RetryConfigurationError.self) {
            _ = try await RetryPolicy.retry(maxRetries: 1, baseDelay: .infinity) { "ok" }
        }
    }

    @Test("Negative baseDelay throws RetryConfigurationError instead of trapping")
    func negativeBaseDelayRejected() async throws {
        // Before PKRR-030: Double.random(in: 0.0 ... (negative * 0.1)) would trap
        // because the range upper bound < lower bound.
        await #expect(throws: RetryConfigurationError.self) {
            _ = try await RetryPolicy.retry(maxRetries: 1, baseDelay: -1.0) { "ok" }
        }
    }

    @Test("maxRetries exceeding hard cap throws RetryConfigurationError")
    func maxRetriesExceedsCapRejected() async throws {
        await #expect(throws: RetryConfigurationError.self) {
            _ = try await RetryPolicy.retry(maxRetries: 100, baseDelay: 0.001) { "ok" }
        }
    }

    @Test("Valid values still work through the legacy signature")
    func validValuesWorkViaLegacySignature() async throws {
        let result = try await RetryPolicy.retry(maxRetries: 3, baseDelay: 0.001) {
            "ok"
        }
        #expect(result == "ok")
    }

    // MARK: - Retry-After is capped by host policy

    @Test("Excessive server Retry-After is capped and does not cause an excessive sleep")
    func retryAfterCappedByHostPolicy() async throws {
        // A hostile server advertises Retry-After: 999999 seconds. Without capping, the
        // retry would sleep for ~16 minutes. With maxRetryAfter: 0.05, the actual sleep
        // should be ~50ms.
        let config = try RetryConfiguration(
            maxRetries: 1,
            baseDelay: 0.001,
            maxRetryAfter: 0.05,
            jitter: .none
        )
        let attempts = Mutex(0)
        let started = ContinuousClock.now

        let result = try await RetryPolicy.retry(
            configuration: config,
            shouldRetry: { _ in true }
        ) {
            attempts.withLock { $0 += 1 }
            if attempts.withLock({ $0 }) == 1 {
                throw LLMServiceError.httpError(
                    provider: "test",
                    statusCode: 429,
                    responseBody: "",
                    retryAfter: 999_999
                )
            }
            return "ok"
        }

        #expect(result == "ok")
        #expect(attempts.withLock { $0 } == 2)
        // The capped delay should be ~0.05s, not ~999999s. Allow generous tolerance for CI.
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(5), "Retry-After was not capped: elapsed \(elapsed)")
    }

    // MARK: - Total elapsed-time budget

    @Test("Retry stops when total elapsed budget is exhausted, before maxRetries")
    func totalElapsedBudgetStopsRetry() async throws {
        // With a short total-elapsed budget and longer per-retry sleeps, the retry
        // should stop due to the elapsed budget well before maxRetries (10).
        // Each retry sleeps ~0.01s; after ~3 retries the 0.02s budget is exhausted.
        let config = try RetryConfiguration(
            maxRetries: 10,
            baseDelay: 0.01,
            maxDelay: 0.01,
            maxTotalElapsedTime: 0.02,
            jitter: .none
        )
        let attempts = Mutex(0)

        await #expect(throws: URLError.self) {
            _ = try await RetryPolicy.retry(
                configuration: config,
                shouldRetry: { _ in true }
            ) {
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }

        let finalAttempts = attempts.withLock { $0 }
        // The budget should have stopped us well before 11 attempts (1 + maxRetries).
        #expect(finalAttempts < 11, "Total-elapsed budget did not stop retries: \(finalAttempts) attempts")
        // But we should have retried at least once.
        #expect(finalAttempts > 1, "Retry did not attempt at least one retry: \(finalAttempts) attempts")
    }

    // MARK: - Configuration-based retry works end-to-end

    @Test("retry(configuration:) succeeds on first attempt")
    func configurationRetrySucceeds() async throws {
        let config = try RetryConfiguration(maxRetries: 3, baseDelay: 0.001)
        let result = try await RetryPolicy.retry(configuration: config) { "ok" }
        #expect(result == "ok")
    }

    @Test("retry(configuration:) retries transient failures and succeeds")
    func configurationRetryRetriesAndSucceeds() async throws {
        let config = try RetryConfiguration(maxRetries: 3, baseDelay: 0.001, jitter: .none)
        let attempts = Mutex(0)
        let result = try await RetryPolicy.retry(configuration: config) {
            attempts.withLock { $0 += 1 }
            if attempts.withLock({ $0 }) <= 2 {
                throw URLError(.timedOut)
            }
            return "recovered"
        }
        #expect(result == "recovered")
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test("retry(configuration:) respects maxRetries")
    func configurationRetryRespectsMaxRetries() async throws {
        let config = try RetryConfiguration(maxRetries: 2, baseDelay: 0.001, jitter: .none)
        let attempts = Mutex(0)
        await #expect(throws: URLError.self) {
            _ = try await RetryPolicy.retry(configuration: config) {
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        #expect(attempts.withLock { $0 } == 3) // 1 initial + 2 retries
    }

    @Test("retry(configuration:) does not retry non-transient errors")
    func configurationRetryDoesNotRetryNonTransient() async throws {
        struct FatalError: Error {}
        let config = try RetryConfiguration(maxRetries: 3, baseDelay: 0.001)
        let attempts = Mutex(0)
        await #expect(throws: FatalError.self) {
            _ = try await RetryPolicy.retry(
                configuration: config,
                shouldRetry: { _ in false }
            ) {
                attempts.withLock { $0 += 1 }
                throw FatalError()
            }
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}
