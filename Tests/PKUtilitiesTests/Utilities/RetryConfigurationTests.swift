import Foundation
import PKContracts
@testable import PKUtilities
import Testing

/// Unit tests for `RetryConfiguration`, `Timeout`, `JitterStrategy`, and their
/// associated error types (PKRR-030).
///
/// These tests verify that invalid numeric values (negative, NaN, infinite, extreme)
/// fail construction with typed errors, and that the validated types produce safe
/// values that cannot trap downstream on `UInt64` conversion or create immediate loops.
@Suite("RetryConfiguration and Timeout validation (PKRR-030)")
struct RetryConfigurationTests {

    // MARK: - RetryConfiguration

    @Suite("RetryConfiguration construction")
    struct RetryConfigurationConstruction {

        @Test("Default configuration matches pre-PKRR-030 behavior")
        func defaultConfiguration() throws {
            let config = try RetryConfiguration()
            #expect(config.maxRetries == 3)
            #expect(config.baseDelay == 1.0)
            #expect(config.maxDelay == 300)
            #expect(config.maxRetryAfter == 300)
            #expect(config.maxTotalElapsedTime == 600)
        }

        @Test("Valid custom values are accepted")
        func validCustomValues() throws {
            let config = try RetryConfiguration(
                maxRetries: 5,
                baseDelay: 2.0,
                maxDelay: 60,
                maxRetryAfter: 30,
                maxTotalElapsedTime: 120
            )
            #expect(config.maxRetries == 5)
            #expect(config.baseDelay == 2.0)
            #expect(config.maxDelay == 60)
            #expect(config.maxRetryAfter == 30)
            #expect(config.maxTotalElapsedTime == 120)
        }

        @Test("Zero retries and zero base delay are valid")
        func zeroValues() throws {
            let config = try RetryConfiguration(maxRetries: 0, baseDelay: 0)
            #expect(config.maxRetries == 0)
            #expect(config.baseDelay == 0)
        }
    }

    @Suite("RetryConfiguration rejects invalid values")
    struct RetryConfigurationRejection {

        @Test("Negative maxRetries fails with negativeMaxRetries")
        func negativeMaxRetries() {
            #expect(throws: RetryConfigurationError.negativeMaxRetries(-1)) {
                _ = try RetryConfiguration(maxRetries: -1)
            }
        }

        @Test("maxRetries exceeding hard cap fails with maxRetriesExceedsHardCap")
        func maxRetriesExceedsCap() {
            #expect(throws: RetryConfigurationError.maxRetriesExceedsHardCap(11, cap: 10)) {
                _ = try RetryConfiguration(maxRetries: 11)
            }
        }

        @Test("NaN baseDelay fails with nonFiniteDelay")
        func nanBaseDelay() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(baseDelay: .nan)
            }
        }

        @Test("Infinite baseDelay fails with nonFiniteDelay")
        func infiniteBaseDelay() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(baseDelay: .infinity)
            }
        }

        @Test("Negative baseDelay fails with negativeDelay")
        func negativeBaseDelay() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(baseDelay: -1.0)
            }
        }

        @Test("baseDelay exceeding max fails with baseDelayExceedsMax")
        func baseDelayExceedsMax() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(baseDelay: 61.0)
            }
        }

        @Test("NaN maxDelay fails")
        func nanMaxDelay() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(maxDelay: .nan)
            }
        }

        @Test("Negative maxRetryAfter fails")
        func negativeMaxRetryAfter() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(maxRetryAfter: -1.0)
            }
        }

        @Test("Infinite maxTotalElapsedTime fails")
        func infiniteMaxTotalElapsedTime() {
            #expect(throws: RetryConfigurationError.self) {
                _ = try RetryConfiguration(maxTotalElapsedTime: .infinity)
            }
        }
    }

    @Suite("RetryConfigurationError properties")
    struct RetryConfigurationErrorProperties {

        @Test("All cases report the utilities domain")
        func errorDomain() {
            #expect(RetryConfigurationError.negativeMaxRetries(-1).errorDomain == PKErrorDomain.utilities)
            #expect(RetryConfigurationError.maxRetriesExceedsHardCap(11, cap: 10).errorDomain == PKErrorDomain.utilities)
            #expect(RetryConfigurationError.nonFiniteDelay(name: "baseDelay", value: .nan).errorDomain == PKErrorDomain.utilities)
            #expect(RetryConfigurationError.negativeDelay(name: "maxDelay", value: -1).errorDomain == PKErrorDomain.utilities)
            #expect(RetryConfigurationError.baseDelayExceedsMax(61, max: 60).errorDomain == PKErrorDomain.utilities)
        }

        @Test("Error codes are unique and stable")
        func errorCodes() {
            #expect(RetryConfigurationError.negativeMaxRetries(-1).errorCode == 5001)
            #expect(RetryConfigurationError.maxRetriesExceedsHardCap(11, cap: 10).errorCode == 5002)
            #expect(RetryConfigurationError.nonFiniteDelay(name: "x", value: .nan).errorCode == 5003)
            #expect(RetryConfigurationError.negativeDelay(name: "x", value: -1).errorCode == 5004)
            #expect(RetryConfigurationError.baseDelayExceedsMax(61, max: 60).errorCode == 5005)
        }

        @Test("userFriendlyMessage is non-empty for each case")
        func userFriendlyMessages() {
            #expect(!RetryConfigurationError.negativeMaxRetries(-1).userFriendlyMessage.isEmpty)
            #expect(!RetryConfigurationError.maxRetriesExceedsHardCap(11, cap: 10).userFriendlyMessage.isEmpty)
            #expect(!RetryConfigurationError.nonFiniteDelay(name: "baseDelay", value: .nan).userFriendlyMessage.isEmpty)
            #expect(!RetryConfigurationError.negativeDelay(name: "maxDelay", value: -1).userFriendlyMessage.isEmpty)
            #expect(!RetryConfigurationError.baseDelayExceedsMax(61, max: 60).userFriendlyMessage.isEmpty)
        }

        @Test("Remediation is provided for all cases")
        func remediation() {
            #expect(RetryConfigurationError.negativeMaxRetries(-1).remediation != nil)
            #expect(RetryConfigurationError.maxRetriesExceedsHardCap(11, cap: 10).remediation != nil)
            #expect(RetryConfigurationError.nonFiniteDelay(name: "x", value: .nan).remediation != nil)
            #expect(RetryConfigurationError.negativeDelay(name: "x", value: -1).remediation != nil)
            #expect(RetryConfigurationError.baseDelayExceedsMax(61, max: 60).remediation != nil)
        }
    }

    // MARK: - Timeout

    @Suite("Timeout construction")
    struct TimeoutConstruction {

        @Test("Valid finite non-negative values are accepted")
        func validValues() throws {
            let t0 = try Timeout(seconds: 0)
            #expect(t0.seconds == 0)
            #expect(t0.nanoseconds == 0)

            let t1 = try Timeout(seconds: 1.5)
            #expect(t1.seconds == 1.5)
            #expect(t1.nanoseconds == 1_500_000_000)

            let t2 = try Timeout(seconds: 60)
            #expect(t2.seconds == 60)
            #expect(t2.nanoseconds == 60_000_000_000)
        }

        @Test("NaN fails with TimeoutValidationError.nonFinite")
        func nanRejected() {
            // NaN != NaN, so we match on type and then verify the case pattern.
            do {
                _ = try Timeout(seconds: .nan)
                Issue.record("Expected TimeoutValidationError for NaN")
            } catch let TimeoutValidationError.nonFinite(value) {
                #expect(value.isNaN)
            } catch {
                Issue.record("Expected nonFinite, got \(error)")
            }
        }

        @Test("Infinite fails with TimeoutValidationError.nonFinite")
        func infiniteRejected() {
            #expect(throws: TimeoutValidationError.nonFinite(.infinity)) {
                _ = try Timeout(seconds: .infinity)
            }
        }

        @Test("Negative fails with TimeoutValidationError.negative")
        func negativeRejected() {
            #expect(throws: TimeoutValidationError.negative(-1)) {
                _ = try Timeout(seconds: -1)
            }
        }
    }

    @Suite("Timeout nanosecond conversion is overflow-safe")
    struct TimeoutNanoseconds {

        @Test("Huge-but-finite value clamps to UInt64.max instead of overflowing")
        func hugeFiniteClamps() throws {
            let huge = try Timeout(seconds: 1e30)
            #expect(huge.nanoseconds == UInt64.max)
        }

        @Test("Zero produces zero nanoseconds")
        func zeroNanoseconds() throws {
            let t = try Timeout(seconds: 0)
            #expect(t.nanoseconds == 0)
        }

        @Test("Static nanoseconds(for:) handles invalid values without trapping")
        func staticConversionInvalidSafe() {
            #expect(Timeout.nanoseconds(for: .nan) == 0)
            #expect(Timeout.nanoseconds(for: .infinity) == 0)
            #expect(Timeout.nanoseconds(for: -1) == 0)
            #expect(Timeout.nanoseconds(for: 1e30) == UInt64.max)
        }
    }

    @Suite("TimeoutValidationError properties")
    struct TimeoutValidationErrorProperties {

        @Test("Error domain is utilities")
        func errorDomain() {
            #expect(TimeoutValidationError.nonFinite(.nan).errorDomain == PKErrorDomain.utilities)
            #expect(TimeoutValidationError.negative(-1).errorDomain == PKErrorDomain.utilities)
        }

        @Test("Error codes are unique and stable")
        func errorCodes() {
            #expect(TimeoutValidationError.nonFinite(.nan).errorCode == 5101)
            #expect(TimeoutValidationError.negative(-1).errorCode == 5102)
        }

        @Test("userFriendlyMessage is non-empty")
        func userFriendlyMessages() {
            #expect(!TimeoutValidationError.nonFinite(.nan).userFriendlyMessage.isEmpty)
            #expect(!TimeoutValidationError.negative(-1).userFriendlyMessage.isEmpty)
        }
    }

    // MARK: - JitterStrategy

    @Suite("JitterStrategy")
    struct JitterStrategyTests {

        @Test(".none returns the delay unchanged (deterministic)")
        func noneIsDeterministic() {
            let jitter = JitterStrategy.none
            #expect(jitter.apply(1.0) == 1.0)
            #expect(jitter.apply(42.0) == 42.0)
            #expect(jitter.apply(0.001) == 0.001)
        }

        @Test(".randomPercent adds jitter in [0, delay * fraction]")
        func randomPercentRange() {
            let jitter = JitterStrategy.randomPercent(upTo: 0.1)
            let delay: TimeInterval = 10.0
            for _ in 0..<100 {
                let result = jitter.apply(delay)
                #expect(result >= delay && result <= delay + delay * 0.1)
            }
        }

        @Test("Custom closure can be injected for deterministic tests")
        func customJitter() {
            let jitter = JitterStrategy { delay in delay + 0.5 }
            #expect(jitter.apply(1.0) == 1.5)
            #expect(jitter.apply(3.0) == 3.5)
        }
    }

    // MARK: - computeDelay (internal)

    @Suite("RetryPolicy.computeDelay capping and jitter (PKRR-030)")
    struct ComputeDelayTests {
        @Test("Server Retry-After is capped by maxRetryAfter")
        func retryAfterCapped() throws {
            let config = try RetryConfiguration(
                maxRetries: 3,
                baseDelay: 1.0,
                maxRetryAfter: 5.0
            )
            let error = LLMServiceError.httpError(
                provider: "test",
                statusCode: 429,
                responseBody: "",
                retryAfter: 999_999
            )
            let delay = RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config)
            #expect(delay == 5.0)
        }

        @Test("Small Retry-After is honored without capping")
        func smallRetryAfterHonored() throws {
            let config = try RetryConfiguration(maxRetryAfter: 300)
            let error = LLMServiceError.httpError(
                provider: "test",
                statusCode: 429,
                responseBody: "",
                retryAfter: 2.0
            )
            let delay = RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config)
            #expect(delay == 2.0)
        }

        @Test("Infinite Retry-After falls through to exponential backoff")
        func infiniteRetryAfterFallsThrough() throws {
            let config = try RetryConfiguration(baseDelay: 1.0, maxDelay: 100, jitter: .none)
            let error = LLMServiceError.httpError(
                provider: "test",
                statusCode: 429,
                responseBody: "",
                retryAfter: .infinity
            )
            let delay = RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config)
            // attempt 1: baseDelay * 2^0 = 1.0, no jitter → 1.0
            #expect(delay == 1.0)
        }

        @Test("NaN Retry-After falls through to exponential backoff")
        func nanRetryAfterFallsThrough() throws {
            let config = try RetryConfiguration(baseDelay: 1.0, maxDelay: 100, jitter: .none)
            let error = LLMServiceError.httpError(
                provider: "test",
                statusCode: 429,
                responseBody: "",
                retryAfter: .nan
            )
            let delay = RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config)
            #expect(delay == 1.0)
        }

        @Test("Exponential backoff is capped by maxDelay")
        func backoffCapped() throws {
            let config = try RetryConfiguration(
                baseDelay: 1.0,
                maxDelay: 5.0,
                jitter: .none
            )
            let error = URLError(.timedOut)
            // attempt 1: 1.0 * 2^0 = 1.0
            #expect(RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config) == 1.0)
            // attempt 2: 1.0 * 2^1 = 2.0
            #expect(RetryPolicy.computeDelay(for: error, attempt: 2, configuration: config) == 2.0)
            // attempt 3: 1.0 * 2^2 = 4.0
            #expect(RetryPolicy.computeDelay(for: error, attempt: 3, configuration: config) == 4.0)
            // attempt 4: 1.0 * 2^3 = 8.0 → capped to 5.0
            #expect(RetryPolicy.computeDelay(for: error, attempt: 4, configuration: config) == 5.0)
            // attempt 5: 1.0 * 2^4 = 16.0 → capped to 5.0
            #expect(RetryPolicy.computeDelay(for: error, attempt: 5, configuration: config) == 5.0)
        }

        @Test("Deterministic jitter produces predictable delays")
        func deterministicJitter() throws {
            let config = try RetryConfiguration(
                baseDelay: 1.0,
                maxDelay: 100,
                jitter: .none
            )
            let error = URLError(.timedOut)
            // With .none jitter, delay = base * 2^(attempt-1) exactly.
            #expect(RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config) == 1.0)
            #expect(RetryPolicy.computeDelay(for: error, attempt: 2, configuration: config) == 2.0)
            #expect(RetryPolicy.computeDelay(for: error, attempt: 3, configuration: config) == 4.0)
        }

        @Test("Zero Retry-After is ignored (falls through to backoff)")
        func zeroRetryAfterIgnored() throws {
            let config = try RetryConfiguration(baseDelay: 1.0, maxDelay: 100, jitter: .none)
            let error = LLMServiceError.httpError(
                provider: "test",
                statusCode: 429,
                responseBody: "",
                retryAfter: 0
            )
            let delay = RetryPolicy.computeDelay(for: error, attempt: 1, configuration: config)
            // retryAfter == 0 is not > 0, so falls through to exponential backoff
            #expect(delay == 1.0)
        }
    }
}
