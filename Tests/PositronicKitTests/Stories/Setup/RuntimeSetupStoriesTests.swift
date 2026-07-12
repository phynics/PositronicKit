import Foundation
import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Runtime setup stories", .serialized) struct RuntimeSetupStoriesTests {
    @Test("OpenAI convenience initialization configures a registered OpenAI client")
    func openAIConvenienceInitialization() async throws {
        let apiKey = "sk-test-key"
        let chat = PositronicKit(openAIKey: apiKey, model: "gpt-4o-mini")

        let config = await chat.llmService.configuration
        #expect(config.provider == .openAI)
        #expect(config.apiKey == apiKey)
        #expect(config.modelName == "gpt-4o-mini")

        let isConfigured = await chat.llmService.isConfigured
        #expect(isConfigured)

        let llm = try #require(chat.llmService as? LLMService)
        let client = await llm.getClient()
        #expect(client is OpenAIClient)
    }

    @Test("OpenRouter convenience initialization configures a registered OpenRouter client")
    func openRouterConvenienceInitialization() async throws {
        let chat = PositronicKit(
            openRouterKey: "or-test-key",
            model: "openai/gpt-4.1-mini",
            endpoint: "https://openrouter.ai/api"
        )

        let config = await chat.llmService.configuration
        #expect(config.provider == .openRouter)
        #expect(config.apiKey == "or-test-key")
        #expect(config.modelName == "openai/gpt-4.1-mini")
        #expect(config.endpoint == "https://openrouter.ai/api")

        let isConfigured = await chat.llmService.isConfigured
        #expect(isConfigured)

        let llm = try #require(chat.llmService as? LLMService)
        let client = await llm.getClient()
        #expect(client is OpenRouterClient)
    }

    @Test("OpenRouter convenience initialization threads applicationURL/applicationTitle into real attribution headers (PKR-4)")
    func openRouterConvenienceInitializationWiresAttribution() async throws {
        let chat = PositronicKit(
            openRouterKey: "or-test-key",
            model: "openai/gpt-4.1-mini",
            applicationURL: "https://example.com/app",
            applicationTitle: "Example App"
        )

        let config = await chat.llmService.configuration
        #expect(config.applicationURL == "https://example.com/app")
        #expect(config.applicationTitle == "Example App")

        let llm = try #require(chat.llmService as? LLMService)
        let client = try #require(await llm.getClient() as? OpenRouterClient)
        let attribution = await client.currentAttribution
        #expect(attribution.applicationURL == "https://example.com/app")
        #expect(attribution.applicationTitle == "Example App")
    }

    @Test("OpenRouter convenience initialization omits attribution when applicationURL/applicationTitle are nil (PKR-4)")
    func openRouterConvenienceInitializationOmitsAttributionWhenNil() async throws {
        let chat = PositronicKit(openRouterKey: "or-test-key", model: "openai/gpt-4.1-mini")

        let llm = try #require(chat.llmService as? LLMService)
        let client = try #require(await llm.getClient() as? OpenRouterClient)
        let attribution = await client.currentAttribution
        #expect(attribution.applicationURL == nil)
        #expect(attribution.applicationTitle == nil)
    }

    @Test("Ollama convenience initialization configures a registered Ollama client")
    func ollamaInitialization() async throws {
        let model = "llama3"
        let chat = PositronicKit(ollamaModel: model)

        let config = await chat.llmService.configuration
        #expect(config.provider == .ollama)
        #expect(config.modelName == model)
        #expect(config.endpoint == "http://localhost:11434")

        let isConfigured = await chat.llmService.isConfigured
        #expect(isConfigured)

        let llm = try #require(chat.llmService as? LLMService)
        let client = await llm.getClient()
        #expect(client is OllamaClient)
    }

    @Test("Custom Ollama endpoint")
    func customOllamaEndpoint() async {
        let endpoint = "http://192.168.1.100:11434"
        let chat = PositronicKit(ollamaModel: "mistral", endpoint: endpoint)

        let config = await chat.llmService.configuration
        #expect(config.endpoint == endpoint)
    }

    @Test("PositronicKit default initialization")
    func defaultInitialization() async {
        let chat = PositronicKit()
        let isConfigured = await chat.llmService.isConfigured
        #expect(!isConfigured, "Default init should not be configured")
    }

    @Test("Unconfigured facade run fails before attempting execution")
    func unconfiguredFacadeRunFails() async throws {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence
        )

        let chat = PositronicKit(configuration: .init(provider: .init(llmService: UnconfiguredLLMService()), persistence: persistence, runtime: .init(workspaceCreator: MockWorkspaceCreator(), workspaceRoot: workspace.root)))

        let timeline = try await chat.timelineManager.createTimeline(title: "Unconfigured")

        await #expect(throws: ChatEngineError.self) {
            _ = try await chat.run(ChatRunRequest(
                timelineId: timeline.id,
                message: "hello"
            ))
        }
    }

    // MARK: - Configuration validation contract tests

    @Test("Configuration with missing API key for non-Ollama provider is invalid")
    func invalidConfigurationMissingApiKey() throws {
        let config = LLMConfiguration(
            endpoint: "https://api.openai.com",
            modelName: "gpt-4o",
            apiKey: "",
            provider: .openAI
        )
        #expect(!config.isValid)
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("Configuration with empty model name is invalid")
    func invalidConfigurationEmptyModel() throws {
        let config = LLMConfiguration(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "sk-test",
            provider: .openAI
        )
        #expect(!config.isValid)
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("Ollama configuration without API key is valid")
    func ollamaConfigurationValidWithoutApiKey() {
        let config = LLMConfiguration(
            endpoint: "http://localhost:11434",
            modelName: "llama3",
            apiKey: "",
            provider: .ollama
        )
        #expect(config.isValid)
    }

    @Test("LLMService with invalid configuration is not configured")
    func serviceNotConfiguredWithInvalidConfig() async {
        let config = LLMConfiguration(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "",
            provider: .openAI
        )
        let service = LLMService(configuration: config)
        let isConfigured = await service.isConfigured
        #expect(!isConfigured)
    }
}
