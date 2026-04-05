import ErrorKit
import Foundation
import Logging
import MonadShared
import OpenAI

public enum RetryPolicy {
    private static let logger = Logger.module(named: "retry-policy")

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
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempts = 0

        while true {
            do {
                return try await operation()
            } catch {
                if attempts >= maxRetries {
                    let msg = ErrorKit.userFriendlyMessage(for: error)
                    logger.error("Max retries (\(maxRetries)) reached. Final error: \(msg)")
                    throw error
                }

                if !shouldRetry(error) {
                    logger.error("Non-retryable error encountered: \(ErrorKit.userFriendlyMessage(for: error))")
                    throw error
                }

                attempts += 1

                // Exponential backoff: base * 2^(attempt-1)
                let delay = baseDelay * pow(2.0, Double(attempts - 1))
                // Add jitter (0-10% of delay)
                let jitter = Double.random(in: 0.0 ... (delay * 0.1))
                let finalDelay = delay + jitter

                let retryMsg = ErrorKit.userFriendlyMessage(for: error)
                let delayStr = String(format: "%.2f", finalDelay)
                logger.warning(
                    "Retry attempt \(attempts)/\(maxRetries) in \(delayStr)s due to: \(retryMsg)"
                )

                try await Task.sleep(nanoseconds: UInt64(finalDelay * 1_000_000_000))
            }
        }
    }

    /// Default logic to determine if an error is transient
    public static func isTransient(error: Error) -> Bool {
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
            default:
                return false
            }
        }

        // Handle Generic NSError (e.g., POSIX errors)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // Re-check codes if it came as NSError
            return isTransient(error: URLError(URLError.Code(rawValue: nsError.code)))
        }

        return false
    }
}
