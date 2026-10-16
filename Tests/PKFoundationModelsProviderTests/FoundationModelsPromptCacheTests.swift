import Foundation
@testable import PKFoundationModelsProvider
import PKContracts
import Testing

/// Foundation Models declares no prompt-cache mechanism (#279).
@Suite("Foundation Models prompt cache")
struct FoundationModelsPromptCacheTests {
    @available(anyAppleOS 26.0, *)
    @Test("the adapter declares no prompt caching")
    func capabilityIsNone() {
        let client = FoundationModelsClient()
        #expect(client.promptCachingCapability == .none)
    }
}
