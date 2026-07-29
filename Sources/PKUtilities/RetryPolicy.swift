import ErrorKit
import Foundation
import Logging
import PKShared

public enum RetryPolicy {
    /// Executes an async operation with retry logic
    /// - Parameters:
    ///   - maxRetries: Maximum number of retries (default: 3)
    ///   - baseDelay: Base delay in seconds for exponential backoff (default: 1.0)
    ///   - shouldRetry: Closure to determine if an error should trigger a retry
    ///     (default: always true for known transient errors)
    ///   - operation: The async operation to execute
    public static func retry<T>(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        shouldRetry: @escaping @Sendable (Error) -> Bool = RetryPolicy.isTransient,
        loggingConfiguration: LoggingConfiguration = .default,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempts = 0
        let logger = loggingConfiguration.logger(named: "retry-policy")

        while true {
            do {
                return try await operation()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw error
                }

                if attempts >= maxRetries {
                    logger.error("Max retries reached", metadata: LoggingMetadata.forError(error, correlationID: "retry"))
                    throw error
                }

                if !shouldRetry(error) {
                    logger.error("Non-retryable error encountered", metadata: LoggingMetadata.forError(error, correlationID: "retry"))
                    throw error
                }

                attempts += 1

                let finalDelay = retryDelay(for: error, attempt: attempts, baseDelay: baseDelay)

                let delayStr = String(format: "%.2f", finalDelay)
                logger.warning(
                    "Retry attempt \(attempts)/\(maxRetries) in \(delayStr)s",
                    metadata: LoggingMetadata.forError(error, correlationID: "retry")
                )

                try await Task.sleep(nanoseconds: UInt64(finalDelay * 1_000_000_000))
            }
        }
    }

    private static func retryDelay(for error: Error, attempt: Int, baseDelay: TimeInterval) -> TimeInterval {
        if let llmError = error as? LLMServiceError,
           case let .httpError(_, _, _, retryAfter?) = llmError,
           retryAfter > 0
        {
            return retryAfter
        }

        // Exponential backoff: base * 2^(attempt-1)
        let delay = baseDelay * pow(2.0, Double(attempt - 1))
        // Add jitter (0-10% of delay)
        let jitter = Double.random(in: 0.0 ... (delay * 0.1))
        return delay + jitter
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
