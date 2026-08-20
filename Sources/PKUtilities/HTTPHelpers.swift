import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKContracts

package enum HTTPHelpers {
    /// Casts a `URLResponse` to `HTTPURLResponse`, throwing a `networkError` if the cast fails.
    ///
    /// Replaces the duplicated `guard let httpResponse = response as? HTTPURLResponse` pattern
    /// across all provider clients.
    package static func ensureHTTPResponse(
        _ response: URLResponse,
        provider: String
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.networkError("Invalid response type from \(provider)")
        }
        return httpResponse
    }

    /// Throws a `ProviderHTTPFailure` error when the response status is outside `200...299`.
    ///
    /// Replaces the duplicated `guard (200...299).contains(...)` +
    /// `ProviderHTTPFailure.sanitize(String(data: data, encoding: .utf8) ?? "")` chain.
    /// `ProviderHTTPFailure.makeError` sanitizes the body internally, so the raw string is
    /// passed without pre-sanitizing.
    package static func ensureSuccessStatus(
        _ response: HTTPURLResponse,
        provider: String,
        body: Data
    ) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            throw ProviderHTTPFailure.makeError(
                provider: provider,
                response: response,
                responseBody: String(data: body, encoding: .utf8) ?? ""
            )
        }
    }

    /// Extracts the `Data` payload from an SSE `data:` line.
    ///
    /// Replaces the duplicated trim/prefix/drop/`[DONE]`/data conversion pattern.
    /// Returns `nil` for empty lines, non-`data:` lines, `[DONE]` sentinels, or
    /// lines whose payload cannot be encoded as UTF-8 `Data`.
    package static func extractSSEData(from line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data: ") else { return nil }
        let dataString = String(trimmed.dropFirst(6))
        guard dataString != "[DONE]" else { return nil }
        return dataString.data(using: .utf8)
    }
}
