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
        let chat = PositronicKitCore(openAIKey: apiKey, model: "gpt-4o-mini")

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

    @Test("Provider registration is explicit, repeatable, and covers OpenAI-compatible")
    func providerRegistrationContract() async {
        PKOpenAIProvider.register()
        PKOpenAIProvider.register()

        #expect(ExternalLLMProviderRegistry.factory(for: .openAI) != nil)
        #expect(ExternalLLMProviderRegistry.factory(for: .openAICompatible) != nil)

        let llm = LLMService(configuration: .init(
            endpoint: "https://example.com/v1",
            modelName: "gpt-4o-mini",
            apiKey: "sk-test-key",
            provider: .openAICompatible
        ))
        let client = await llm.getClient()
        #expect(client is OpenAIClient)
    }

    @Test("Provider registry supports concurrent defensive registration")
    func providerRegistrySupportsConcurrentDefensiveRegistration() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    let provider: LLMProvider = index.isMultiple(of: 2) ? .openAI : .openAICompatible
                    ExternalLLMProviderRegistry.register(factory: { _, _, _, _, _ in nil }, for: provider)
                    _ = ExternalLLMProviderRegistry.factory(for: provider)
                }
            }
        }

        #expect(ExternalLLMProviderRegistry.factory(for: .openAI) != nil)
        #expect(ExternalLLMProviderRegistry.factory(for: .openAICompatible) != nil)
    }

    @Test("OpenRouter convenience initialization configures a registered OpenRouter client")
    func openRouterConvenienceInitialization() async throws {
        let chat = PositronicKitCore(
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

    @Test("Ollama convenience initialization configures a registered Ollama client")
    func ollamaInitialization() async throws {
        let model = "llama3"
        let chat = PositronicKitCore(ollamaModel: model)

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
        let chat = PositronicKitCore(ollamaModel: "mistral", endpoint: endpoint)

        let config = await chat.llmService.configuration
        #expect(config.endpoint == endpoint)
    }

    @Test("PositronicKitCore default initialization")
    func defaultInitialization() async {
        let chat = PositronicKitCore()
        let isConfigured = await chat.llmService.isConfigured
        #expect(!isConfigured, "Default init should not be configured")
    }

    @Test("Unconfigured facade run fails before attempting execution")
    func unconfiguredFacadeRunFails() async throws {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )

        let timeline = try await timelineManager.createTimeline(title: "Unconfigured")

        let persistence = PositronicKitCore.PersistenceConfiguration(
            messageStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence
        )

        let chat = PositronicKitCore(
            llmService: UnconfiguredLLMService(),
            persistence: persistence,
            runtime: .init(timelineManager: timelineManager)
        )

        await #expect(throws: ChatEngineError.self) {
            _ = try await chat.run(timelineId: timeline.id, message: "hello")
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
