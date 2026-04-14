import Foundation

public enum LLMProvider: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case openAICompatible = "OpenAI Compatible"
    case ollama = "Ollama"

    public var id: String {
        rawValue
    }
}
