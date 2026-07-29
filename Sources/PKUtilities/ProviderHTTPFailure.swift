import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PKShared

package enum ProviderHTTPFailure {
    package static func makeError(
        provider: String,
        response: HTTPURLResponse,
        responseBody: String
    ) -> LLMServiceError {
        LLMServiceError.httpError(
            provider: provider,
            statusCode: response.statusCode,
            responseBody: sanitize(responseBody),
            retryAfter: parseRetryAfter(from: response)
        )
    }

    package static func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        // PKRR-030: reject non-finite values (NaN, infinity) that would later trap on
        // UInt64 nanosecond conversion. A hostile or buggy server could send "Retry-After: inf".
        if let seconds = TimeInterval(rawValue), seconds > 0, seconds.isFinite {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let date = formatter.date(from: rawValue) else { return nil }
        let elapsed = max(0, date.timeIntervalSinceNow)
        return elapsed.isFinite ? elapsed : nil
    }

    package static func sanitize(_ responseBody: String, limit: Int = LimitedErrorBodyCollector.defaultLimit) -> String {
        guard limit > 0 else { return "" }

        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let sanitized = trimmed
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        if sanitized.count <= limit {
            return sanitized
        }

        let endIndex = sanitized.index(sanitized.startIndex, offsetBy: limit)
        return String(sanitized[..<endIndex])
    }
}
