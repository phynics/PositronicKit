import Foundation
@testable import PositronicKit
@testable import PKShared
import PKTestSupport
import Testing

@Suite struct InitializationTests {
    @Test("Simplified OpenAI initialization")
    func openAIInitialization() async throws {
        let apiKey = "sk-test-key"
        let chat = MonadCore(openAIKey: apiKey)
        
        let config = await chat.llmService.configuration
        #expect(config.provider == .openAI)
        #expect(config.apiKey == apiKey)
        #expect(config.modelName == "gpt-4o")
        
        let isConfigured = await chat.llmService.isConfigured
        #expect(isConfigured)
    }
    
    @Test("Simplified Ollama initialization")
    func ollamaInitialization() async throws {
        let model = "llama3"
        let chat = MonadCore(ollamaModel: model)
        
        let config = await chat.llmService.configuration
        #expect(config.provider == .ollama)
        #expect(config.modelName == model)
        #expect(config.endpoint == "http://localhost:11434")
        
        let isConfigured = await chat.llmService.isConfigured
        #expect(isConfigured)
    }
    
    @Test("Custom Ollama endpoint")
    func customOllamaEndpoint() async throws {
        let endpoint = "http://192.168.1.100:11434"
        let chat = MonadCore(ollamaModel: "mistral", endpoint: endpoint)
        
        let config = await chat.llmService.configuration
        #expect(config.endpoint == endpoint)
    }

    @Test("MonadCore default initialization")
    func defaultInitialization() async throws {
        let chat = MonadCore()
        let isConfigured = await chat.llmService.isConfigured
        #expect(!isConfigured, "Default init should not be configured")
    }
}
