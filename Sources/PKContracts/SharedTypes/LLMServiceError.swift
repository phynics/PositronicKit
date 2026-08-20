import Foundation

/// Provider-neutral errors returned by a language-model adapter.
public enum LLMServiceError: PKError, Equatable {
    case notConfigured
    case invalidConfiguration
    case networkError(String)
    case httpError(provider: String, statusCode: Int, responseBody: String, retryAfter: TimeInterval?)
    case emptyResponse(provider: String)
    case unexpectedResponse(provider: String, reason: String)
    case clientNotResolved(provider: String)

    public var errorDomain: String { PKErrorDomain.llm }

    public var errorCode: Int {
        switch self {
        case .notConfigured: return 1001
        case .invalidConfiguration: return 1002
        case .networkError: return 1003
        case .httpError: return 1004
        case .emptyResponse: return 1006
        case .unexpectedResponse: return 1007
        case .clientNotResolved: return 1008
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .notConfigured:
            return "LLM service is not configured. Please set up your API endpoint and key."
        case .invalidConfiguration:
            return "Invalid LLM configuration. Please check your settings."
        case .clientNotResolved(let provider):
            return "LLM configuration is valid for \(provider), but no client could be created. Register a client factory for this provider."
        case let .networkError(message):
            return "Network error: \(message)"
        case let .httpError(provider, statusCode, responseBody, _):
            let body = responseBody
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let limited = String(body.prefix(8 * 1024))
            return limited.isEmpty
                ? "\(provider) request failed with HTTP \(statusCode)."
                : "\(provider) request failed with HTTP \(statusCode): \(limited)"
        case let .emptyResponse(provider):
            return "\(provider) returned an empty response where output was required."
        case let .unexpectedResponse(provider, reason):
            return "\(provider) returned an unexpected response: \(reason)"
        }
    }
}
