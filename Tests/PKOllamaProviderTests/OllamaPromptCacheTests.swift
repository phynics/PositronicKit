import Foundation
@testable import PKOllamaProvider
import PKContracts
import Testing

/// Ollama declares no prompt-cache mechanism (#279).
@Suite("Ollama prompt cache")
struct OllamaPromptCacheTests {
    @Test("the adapter declares no prompt caching")
    func capabilityIsNone() {
        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3")
        #expect(client.promptCachingCapability == .none)
    }
}
