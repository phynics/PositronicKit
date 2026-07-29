import Foundation
import Logging
import PKShared

public enum RetryPolicy {
    /// Executes an async operation with retry logic.
    ///
    /// This overload accepts raw `maxRetries` and `baseDelay` values for backward
    /// compatibility. Invalid values (negative, NaN, infinite, or exceeding hard caps)
    /// fail with a typed `RetryConfigurationError` before the retry loop starts
    /// (PKRR-030), rather than producing immediate loops, excessive sleeps, or
    /// `UInt64` conversion traps.
    ///
    /// - Parameters:
    ///   - maxRetries: Maximum number of retries (default: 3). Must be in `0...10`.
    ///   - baseDelay: Base delay in seconds for exponential backoff (default: 1.0).
    ///     Must be finite, non-negative, and ≤ 60.
    ///   - shouldRetry: Closure to determine if an error should trigger a retry
    ///     (default: always true for known transient errors)
    ///   - loggingConfiguration: Logging configuration.
    ///   - operation: The async operation to execute.
    public static func retry<T>(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        shouldRetry: @escaping @Sendable (Error) -> Bool = RetryPolicy.isTransient,
        loggingConfiguration: LoggingConfiguration = .default,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let configuration = try RetryConfiguration(maxRetries: maxRetries, baseDelay: baseDelay)
        return try await retry(
            configuration: configuration,
            shouldRetry: shouldRetry,
            loggingConfiguration: loggingConfiguration,
            operation: operation
        )
    }

    /// Executes an async operation with a validated `RetryConfiguration`.
    ///
    /// The configuration enforces finite delay ranges, caps server-advertised
    /// `Retry-After` hints by `maxRetryAfter`, and enforces a total wall-clock
    /// elapsed budget (`maxTotalElapsedTime`) so a hostile or buggy server cannot
    /// keep the caller retrying indefinitely (PKRR-030).
    ///
    /// - Parameters:
    ///   - configuration: Validated retry configuration (delays, caps, budgets, jitter).
    ///   - shouldRetry: Closure to determine if an error should trigger a retry
    ///     (default: always true for known transient errors).
    ///   - loggingConfiguration: Logging configuration.
    ///   - operation: The async operation to execute.
    public static func retry<T>(
        configuration: RetryConfiguration,
        shouldRetry: @escaping @Sendable (Error) -> Bool = RetryPolicy.isTransient,
        loggingConfiguration: LoggingConfiguration = .default,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempts = 0
        let startTime = ContinuousClock.now
        let logger = loggingConfiguration.logger(named: "retry-policy")

        while true {
            do {
                return try await operation()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw error
                }

                if attempts >= configuration.maxRetries {
                    logger.error("Max retries reached", metadata: LoggingMetadata.forError(error, correlationID: "retry"))
                    throw error
                }

                // Total elapsed-time budget: stop retrying if the wall-clock budget is exhausted,
                // even if the attempt count has not yet hit maxRetries (PKRR-030).
                let elapsed = startTime.duration(to: .now)
                if elapsed >= .seconds(configuration.maxTotalElapsedTime) {
                    logger.error(
                        "Retry total elapsed budget exhausted (\(configuration.maxTotalElapsedTime)s) after \(attempts) attempts",
                        metadata: LoggingMetadata.forError(error, correlationID: "retry")
                    )
                    throw error
                }

                if !shouldRetry(error) {
                    logger.error("Non-retryable error encountered", metadata: LoggingMetadata.forError(error, correlationID: "retry"))
                    throw error
                }

                attempts += 1

                let finalDelay = computeDelay(for: error, attempt: attempts, configuration: configuration)

                let delayStr = String(format: "%.2f", finalDelay)
                logger.warning(
                    "Retry attempt \(attempts)/\(configuration.maxRetries) in \(delayStr)s",
                    metadata: LoggingMetadata.forError(error, correlationID: "retry")
                )

                try await Task.sleep(nanoseconds: Timeout.nanoseconds(for: finalDelay))
            }
        }
    }

    /// Computes the retry delay for a given error and attempt number, applying the
    /// configuration's jitter, `maxDelay` cap, and `maxRetryAfter` cap (PKRR-030).
    ///
    /// - If the error carries a finite, positive `Retry-After` hint, it is honored
    ///   but capped by `configuration.maxRetryAfter` (no jitter applied to server hints).
    /// - Otherwise, exponential backoff (`baseDelay * 2^(attempt-1)`) with jitter is
    ///   used, capped by `configuration.maxDelay`.
    static func computeDelay(
        for error: Error,
        attempt: Int,
        configuration: RetryConfiguration
    ) -> TimeInterval {
        if let llmError = error as? LLMServiceError,
           case let .httpError(_, _, _, retryAfter?) = llmError,
           retryAfter > 0,
           retryAfter.isFinite
        {
            return min(retryAfter, configuration.maxRetryAfter)
        }

        // Exponential backoff: base * 2^(attempt-1)
        let delay = configuration.baseDelay * pow(2.0, Double(attempt - 1))
        // Apply jitter strategy (deterministic for tests via configuration.jitter)
        let jittered = configuration.jitter.apply(delay)
        return min(jittered, configuration.maxDelay)
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500 ... 599).contains(statusCode)
    }

    /// Default logic to determine if an error is transient
    public static func isTransient(error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return false
        }

        // Handle URLSession Errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .httpTooManyRedirects,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        // Handle LLMService Errors
        if let llmError = error as? LLMServiceError {
            switch llmError {
            case .networkError:
                return true
            case let .httpError(_, statusCode, _, _):
                return isRetryableHTTPStatus(statusCode)
            default:
                return false
            }
        }
        // Handle Generic NSError (e.g., POSIX errors)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // Re-check codes if it came as NSError.
            // URLError.Code(rawValue:) is failable on swift-corelibs-foundation (Linux)
            // but non-failable on Apple platforms, so the two branches can't share one expression.
            #if canImport(FoundationNetworking)
                guard let code = URLError.Code(rawValue: nsError.code) else { return false }
            #else
                let code = URLError.Code(rawValue: nsError.code)
            #endif
            return isTransient(error: URLError(code))
        }

        return false
    }
}
