import Foundation
import MonadCore
import MonadShared
import Testing

@Suite struct LLMConfigurationTests {

    @Test("Default configuration validity")
    func defaultConfiguration() {
        let config = LLMConfiguration.openAI
        #expect(!config.isValid) // Invalid because API key is empty
        #expect(config.provider == .openAI)
        #expect(config.timeoutInterval == 60.0)
        #expect(config.maxRetries == 3)
    }

    @Test("Valid OpenAI configuration")
    func validOpenAI() {
        let config = LLMConfiguration(
            endpoint: "https://api.openai.com",
            modelName: "gpt-4",
            apiKey: "sk-12345",
            provider: .openAI
        )
        #expect(config.isValid)
        #expect(config.timeoutInterval == 60.0)
    }

    @Test("Valid Ollama configuration (No API Key)")
    func validOllama() {
        let config = LLMConfiguration(
            endpoint: "http://localhost:11434",
            modelName: "llama3",
            apiKey: "",
            provider: .ollama
        )
        #expect(config.isValid)
        #expect(config.timeoutInterval == 60.0)
    }

    @Test("Invalid Endpoint")
    func invalidEndpoint() {
        let config = LLMConfiguration(
            endpoint: "not-a-url",
            modelName: "gpt-4",
            apiKey: "sk-123",
            provider: .openAI
        )
        #expect(!config.isValid)
    }

    @Test("Missing Model Name")
    func missingModel() {
        let config = LLMConfiguration(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "sk-123",
            provider: .openAI
        )
        #expect(!config.isValid)
    }

    @Test("Custom timeout and retries")
    func customTimeoutAndRetries() {
        var config = LLMConfiguration.openAI
        config.timeoutInterval = 30.0
        config.maxRetries = 10

        #expect(config.timeoutInterval == 30.0)
        #expect(config.maxRetries == 10)
    }

    @Test("Legacy JSON Decoding")
    func legacyJSONDecoding() throws {
        // Simulating JSON (dictionary format)
        let json = """
        {
            "activeProvider": "OpenAI",
            "providers": {
                "OpenAI": {
                    "endpoint": "https://api.openai.com",
                    "apiKey": "sk-123",
                    "modelName": "gpt-4",
                    "utilityModel": "gpt-3.5",
                    "fastModel": "gpt-3.5",
                    "toolFormat": "Native (OpenAI)"
                }
            },
            "mcpServers": [],
            "memoryContextLimit": 5,
            "documentContextLimit": 5,
            "version": 5
        }
        """
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }

        let config = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        #expect(config.timeoutInterval == 60.0)
        #expect(config.maxRetries == 3)
    }
}
