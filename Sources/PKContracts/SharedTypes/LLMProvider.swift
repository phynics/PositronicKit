import Foundation

/// Identifies which LLM backend a configuration or client targets.
///
/// The raw value is the human-readable provider name used in persisted configuration
/// and UI display; it is not necessarily the wire-format identifier used by any given API.
public enum LLMProvider: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    /// OpenAI's hosted API.
    case openAI = "OpenAI"
    /// OpenRouter's multi-model routing API.
    case openRouter = "OpenRouter"
    /// A third-party endpoint that speaks the OpenAI-compatible chat completions API.
    case openAICompatible = "OpenAI Compatible"
    /// A local or remote Ollama server.
    case ollama = "Ollama"
    /// Anthropic's hosted API.
    case anthropic = "Anthropic"

    public var id: String {
        rawValue
    }
}
