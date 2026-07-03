import Foundation

/// Shared normalization vocabulary for LLM provider "finish reason" signals (PKR-13).
///
/// Each provider adapter (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`)
/// historically derived the public `finishReason: String?` fields on `APIResponseMetadata`
/// and `LLMStreamChoice` independently, each with its own ad hoc vocabulary:
/// - OpenAI mapped its SDK's `ChatResult.Choice.FinishReason.rawValue` directly.
/// - OpenRouter passed its wire string (`finish_reason`) through unchanged.
/// - Ollama synthesized only `"tool_calls"`/`"stop"`, silently discarding the wire
///   `done_reason` field, so a truncated (length-limited) response was indistinguishable
///   from a normal stop.
///
/// `FinishReason` is an internal-normalization layer: adapters map their provider-specific
/// signal onto this enum first, then derive the final `String` they assign to the existing
/// public `String?` fields via ``wireValue``. This keeps those fields' *type* and existing
/// wire *values* unchanged (no breaking change for downstream consumers that compare against
/// bare strings, e.g. Yakamoz's `ChatEventReducer`), while giving every adapter one shared
/// vocabulary to map onto and giving Ollama a way to faithfully represent truncation.
public enum FinishReason: Sendable, Equatable {
    /// The model reached a natural stopping point (e.g. an end-of-turn token).
    case stop
    /// The model produced one or more tool/function calls.
    case toolCalls
    /// Generation was truncated because a token/length limit was reached.
    case length
    /// The provider's content-filtering system stopped or redacted generation.
    case contentFilter
    /// Any other provider-specific reason, preserved verbatim as a passthrough.
    case other(String)

    /// The wire-compatible string value assigned to the existing `finishReason: String?`
    /// fields. Matches the vocabulary already in use across adapters/tests (`"stop"`,
    /// `"tool_calls"`, `"length"`, `"content_filter"`), so this is purely an internal
    /// normalization step — it does not change any observed wire value for existing cases.
    public var wireValue: String {
        switch self {
        case .stop:
            return "stop"
        case .toolCalls:
            return "tool_calls"
        case .length:
            return "length"
        case .contentFilter:
            return "content_filter"
        case let .other(value):
            return value
        }
    }

    /// Maps a raw provider wire string onto the shared vocabulary. Recognizes the common
    /// OpenAI-family values (`stop`, `tool_calls`, `length`, `content_filter`); anything else
    /// is preserved via `.other(_:)` so no information is lost.
    public init(wireValue: String) {
        switch wireValue {
        case "stop":
            self = .stop
        case "tool_calls":
            self = .toolCalls
        case "length":
            self = .length
        case "content_filter":
            self = .contentFilter
        default:
            self = .other(wireValue)
        }
    }
}
