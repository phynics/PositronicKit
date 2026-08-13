import Foundation
import PKShared
import PKTestSupport
import PositronicKit
import Testing

@Suite("Runtime setup stories", .serialized) struct RuntimeSetupStoriesTests {
    @Test("PositronicKit default initialization")
    func defaultInitialization() async {
        let chat = PositronicKit()
        let isConfigured = await chat.isLanguageModelConfigured
        #expect(!isConfigured, "Default init should not be configured")
    }

    @Test("Unconfigured facade run fails before attempting execution")
    func unconfiguredFacadeRunFails() async throws {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: mockPersistence,
            threadPersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence
        )

        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: UnconfiguredLLMService()), persistence: persistence, runtime: .init(workspaceCreator: MockWorkspaceCreator(), workspaceRoot: workspace.root)))

        let thread = try await chat.threadManager.createThread(title: "Unconfigured")

        do {
            _ = try await chat.run(ChatRunRequest(
                threadID: thread.id,
                message: "hello"
            ))
            Issue.record("Expected the unconfigured run to fail synchronously")
        } catch {
            let identity = ChatEvent.ErrorIdentity.extracting(from: error)
            #expect(identity?.domain == PKErrorDomain.chat)
            #expect(identity?.code == 9001)
        }
    }

    // MARK: - Configuration validation contract tests

    @Test("Configuration with missing API key for non-Ollama provider is invalid")
    func invalidConfigurationMissingApiKey() throws {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "gpt-4o",
            apiKey: "",
            activeProvider: .openAI
        )
        #expect(!config.isValid)
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("Configuration with empty model name is invalid")
    func invalidConfigurationEmptyModel() throws {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "sk-test",
            activeProvider: .openAI
        )
        #expect(!config.isValid)
        #expect(throws: ConfigurationError.self) {
            try config.validate()
        }
    }

    @Test("Ollama configuration without API key is valid")
    func ollamaConfigurationValidWithoutApiKey() {
        let config = LLMConfiguration.fixture(
            endpoint: "http://localhost:11434",
            modelName: "llama3",
            apiKey: "",
            activeProvider: .ollama
        )
        #expect(config.isValid)
    }

    @Test("LLMService with invalid configuration is not configured")
    func serviceNotConfiguredWithInvalidConfig() async {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "",
            activeProvider: .openAI
        )
        let service = LLMService(configuration: config)
        let isConfigured = await service.isConfigured
        #expect(!isConfigured)
    }
}
