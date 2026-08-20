import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

struct LLMConfigurationTests {
    @Test("Default configuration validity")
    func defaultConfiguration() {
        let config = LLMConfiguration.openAI
        #expect(!config.isValid) // Invalid because API key is empty
        #expect(config.activeProvider == .openAI)
        #expect(config.activeProviderConfiguration.timeoutInterval == 60.0)
        #expect(config.activeProviderConfiguration.maxRetries == 3)
    }

    @Test("Valid OpenAI configuration")
    func validOpenAI() {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "gpt-4",
            apiKey: "sk-12345",
            activeProvider: .openAI
        )
        #expect(config.isValid)
        #expect(config.activeProviderConfiguration.timeoutInterval == 60.0)
    }

    @Test("Valid Ollama configuration (No API Key)")
    func validOllama() {
        let config = LLMConfiguration.fixture(
            endpoint: "http://localhost:11434",
            modelName: "llama3",
            apiKey: "",
            activeProvider: .ollama
        )
        #expect(config.isValid)
        // Ollama's canonical default is 120s (local models can be slower), not the flat
        // init's old universal 60s default.
        #expect(config.activeProviderConfiguration.timeoutInterval == 120.0)
    }

    @Test("Invalid Endpoint")
    func invalidEndpoint() {
        let config = LLMConfiguration.fixture(
            endpoint: "not-a-url",
            modelName: "gpt-4",
            apiKey: "sk-123",
            activeProvider: .openAI
        )
        #expect(!config.isValid)
    }

    @Test("Missing Model Name")
    func missingModel() {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "sk-123",
            activeProvider: .openAI
        )
        #expect(!config.isValid)
    }

    @Test("Custom timeout and retries")
    func customTimeoutAndRetries() {
        var config = LLMConfiguration.openAI
        config.providers[config.activeProvider]?.timeoutInterval = 30.0
        config.providers[config.activeProvider]?.maxRetries = 10

        #expect(config.activeProviderConfiguration.timeoutInterval == 30.0)
        #expect(config.activeProviderConfiguration.maxRetries == 10)
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
        #expect(config.activeProviderConfiguration.timeoutInterval == 60.0)
        #expect(config.activeProviderConfiguration.maxRetries == 3)
    }
}
