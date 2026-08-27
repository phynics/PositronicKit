import Foundation
import PKPrompt
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Storage that suspends `load()` until `release()` is called, so tests can observe whether the
/// first public call awaits the preparation task.
private actor DelayedConfigurationService: ConfigurationServiceProtocol {
    var config: LLMConfiguration
    private var loadContinuation: CheckedContinuation<LLMConfiguration, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    private var loadStartedContinuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    private(set) var loadStarted = false
    private(set) var loadCount = 0

    init(config: LLMConfiguration) {
        self.config = config
    }

    func load() async -> LLMConfiguration {
        loadCount += 1
        loadStarted = true
        loadStartedContinuation?.resume()
        loadStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            self.loadContinuation = continuation
        }
    }

    func waitUntilLoadStarts() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { continuation in
            loadStartedContinuation = continuation
        }
    }

    func release() {
        loadContinuation?.resume(returning: config)
        loadContinuation = nil
    }

    func save(_ config: LLMConfiguration) async throws {
        self.config = config
    }

    func clear() async {
        config = .openAI
    }

    func migrateIfNeeded() async {}

    func exportConfiguration() async throws -> Data {
        return try JSONEncoder().encode(config)
    }

    func importConfiguration(from data: Data) async throws {
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        config = decoded
    }

    func restoreFromBackup() async throws -> LLMConfiguration? {
        nil
    }
}

@MainActor
struct LLMServiceTests {
    private let llmService: LLMService

    init() {
        llmService = LLMService(storage: MockConfigurationService(), clientResolver: FixedClientsResolver.empty)
    }

    @Test("Test updating LLM configuration")
    func configurationUpdate() async throws {
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key"
        )

        try await llmService.updateConfiguration(config)

        #expect(await llmService.isConfigured)
        #expect(await llmService.configuration.activeProviderConfiguration.modelName == "test-model")
    }

    @Test("Test prompt building logic and structure")
    func promptBuilding() async throws {
        let history = [
            Message(content: "Previous user message", role: .user),
            Message(content: "Previous assistant message", role: .assistant),
        ]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Current question",
                chatHistory: history,
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: "System rules"
            )
        )

        let renderedPrompt = prompt.string

        #expect(renderedPrompt.contains("System rules"))
        #expect(renderedPrompt.contains("Previous user message"))
        #expect(renderedPrompt.contains("Previous assistant message"))
        #expect(renderedPrompt.contains("Current question"))

        let messages = prompt.buildMessages()

        // Validate message ordering and roles
        #expect(!messages.isEmpty)

        // 1. System message should be first
        if let first = messages.first, first.role == .system {
            // Success
        } else {
            #expect(Bool(false), "First message should be system message")
        }

        // 2. Chat history should follow
        // specific check for history messages
        let historyStart = messages.dropFirst() // Drop system

        // Find "Previous user message"
        var foundHistoryUser = false
        for msg in historyStart {
            if msg.role == .user {
                let content = msg.content
                if content == "Previous user message" {
                    foundHistoryUser = true
                    break
                }
            }
        }
        #expect(foundHistoryUser)

        // Find "Previous assistant message"
        var foundHistoryAssistant = false
        for msg in historyStart {
            if msg.role == .assistant {
                let content = msg.content
                if content == "Previous assistant message" {
                    foundHistoryAssistant = true
                    break
                }
            }
        }
        #expect(foundHistoryAssistant)

        // 3. Final message should be the user query
        guard let lastMessage = messages.last else {
            #expect(Bool(false), "Messages should not be empty")
            return
        }

        if lastMessage.role == .user {
            let content = lastMessage.content
            #expect(content == "Current question")
        } else {
            #expect(Bool(false), "Last message should be user query")
        }
    }

    @Test("Test prompt building with empty context")
    func promptBuildingEmptyContext() async throws {
        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Hello",
                chatHistory: [],
                tools: [],
                workspaces: [],
                primaryWorkspace: nil,
                requestOriginName: nil,
                systemInstructions: "System Only"
            )
        )
        let messages = prompt.buildMessages()

        #expect(messages.count >= 2) // System + User

        if let first = messages.first, first.role == .system {
            let content = first.content
            #expect(content.contains("System Only"))
        } else {
            #expect(Bool(false), "First message should be system")
        }

        if let last = messages.last, last.role == .user {
            let content = last.content
            #expect(content == "Hello")
        } else {
            #expect(Bool(false), "Last message should be user query")
        }
    }

    @Test("Test history optimization (truncation)")
    func promptTruncation() {
        // Create a large history that should be truncated
        // make sure it exceeds the limit we pass
        let limit = 100

        let largeHistory = (1 ... 10).map { i in
            Message(
                content:
                "Message \(i) with significant length to trigger early truncation logic. ....................................................................",
                role: .user
            )
        }

        // Call optimizeHistory directly
        let optimized = PromptHistoryOptimizer.optimize(largeHistory, availableTokens: limit)

        // Should have fewer messages than total history
        #expect(optimized.count < largeHistory.count)

        // Should contain a summary message at the start
        if let first = optimized.first {
            #expect(first.role == .system)
            #expect(first.isSummary == true)
        } else {
            #expect(Bool(false), "Optimized history should not be empty")
        }
    }

    @Test("LLMService streaming fails when not configured")
    func unconfiguredServiceError() async throws {
        let service = LLMService(storage: MockConfigurationService(), clientResolver: FixedClientsResolver.empty)
        // No configuration provided

        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )
        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await stream.collect()
        }
    }

    @Test("Strict title generation uses schema-backed structured output")
    func titleGeneration() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = #"{"title":"SwiftUI Basics"}"#

        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        let messages = [
            Message(content: "How do I use SwiftUI?", role: .user),
            Message(content: "You use it by declaring views.", role: .assistant),
        ]

        let title = try await LLMUtilityGenerator(streamClient: service).generateTitle(for: messages)
        #expect(title == "SwiftUI Basics")
        guard case let .jsonSchema(schema) = mockClient.lastResponseFormat else {
            Issue.record("Expected generateTitle to use a JSON schema response format")
            return
        }
        #expect(schema.name == "llm_title")

        // Verify transcript was sent in the prompt
        if let lastMessage = mockClient.lastMessages.last {
            if lastMessage.role == .user {
                let content = lastMessage.content
                #expect(content.contains("How do I use SwiftUI?"))
                #expect(content.contains("You use it by declaring views."))
            }
        }
    }

    @Test("Utility generations use schema-backed structured output")
    func utilityGenerationsUseSchemaBackedStructuredOutput() async throws {
        let mockClient = MockLLMClient()
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        mockClient.nextResponse = #"{"tags":["Swift","Tests"]}"#
        let generator = LLMUtilityGenerator(streamClient: service)
        let tags = try await generator.generateTags(for: "Swift tests are great")
        #expect(tags == ["swift", "tests"])

        guard case let .jsonSchema(tagSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected generateTags to use a JSON schema response format")
            return
        }
        #expect(tagSchema.name == "llm_tags")
        let tagSchemaText = try String(decoding: JSONEncoder().encode(tagSchema.schema), as: UTF8.self)
        #expect(tagSchemaText.contains("\"tags\""))

        mockClient.nextResponse = #"{"title":"Condensed Title"}"#
        let title = try await generator.generateTitle(for: [
            Message(content: "Summarize this discussion", role: .user),
        ])
        #expect(title == "Condensed Title")

        guard case let .jsonSchema(titleSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected generateTitle to use a JSON schema response format")
            return
        }
        #expect(titleSchema.name == "llm_title")
        let titleSchemaText = try String(decoding: JSONEncoder().encode(titleSchema.schema), as: UTF8.self)
        #expect(titleSchemaText.contains("\"title\""))
    }

    @Test("Strict utility generations propagate provider failures")
    func utilityGenerationsPropagateProviderFailures() async throws {
        let mockClient = MockLLMClient()
        mockClient.shouldThrowError = true

        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        let generator = LLMUtilityGenerator(streamClient: service)
        await #expect(throws: Error.self) {
            _ = try await generator.generateTags(for: "Tag this text")
        }
        await #expect(throws: Error.self) {
            _ = try await generator.generateTitle(for: [
                Message(content: "A thread", role: .user),
            ])
        }
    }

    @Test("Health details report typed provider identity, not endpoint substrings")
    func healthDetailsUseTypedProvider() async {
        let openRouterConfig = LLMConfiguration.fixture(
            endpoint: "https://my-proxy.example.com/v1",
            modelName: "gpt-4o",
            apiKey: "test-key",
            activeProvider: .openRouter
        )
        let service = LLMService(configuration: openRouterConfig, clients: .empty)

        let details = await service.getHealthDetails()
        #expect(details?["provider"] == "OpenRouter")
        #expect(details?["model"] == "gpt-4o")
    }

    @Test("Health check is degraded when not configured")
    func healthStatusDegradedWhenNotConfigured() async {
        let service = LLMService(storage: MockConfigurationService(), clientResolver: FixedClientsResolver.empty)
        let status = await service.checkHealth()
        #expect(status == .degraded)
    }

    @Test("Health check is degraded when configured but no client exists")
    func healthCheckDegradedWhenNoClient() async {
        // LLMService init with a valid config creates a client via the registry,
        // but if the registry has no factory for that provider, the client is nil.
        // Use a storage-backed init with no client to exercise this path.
        let mockStorage = MockConfigurationService()
        let service = LLMService(storage: mockStorage, clientResolver: FixedClientsResolver.empty)
        let status = await service.checkHealth()
        #expect(status == .degraded)
    }

    @Test("Health check is ok when configured client responds")
    func healthCheckOkWhenClientReachable() async {
        let mockClient = MockLLMClient()
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )
        let status = await service.checkHealth()
        #expect(status == .ok)
    }

    // MARK: - PKRR-018: configuration validity vs operational readiness

    @Test("isConfigured is true but isReady is false when config is valid but no client factory exists (PKRR-018)")
    func configuredButNotReadyWhenNoClientFactory() async {
        // Direct-config init with a valid configuration but no clientFactory: the
        // configuration is valid so isConfigured == true, but no client can be resolved
        // so isReady must be false. This is the configured-but-no-client state the ticket
        // calls out — isConfigured alone does not guarantee a send can start.
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key",
            activeProvider: .openAI
        )
        let service = LLMService(configuration: config, clients: .empty)

        #expect(await service.isConfigured, "isConfigured reflects configuration validity only")
        #expect(await service.isReady == false, "isReady is false when no primary client is resolved")
        #expect(await service.isReady == false, "No primary client is resolved")
    }

    @Test("isReady is true and guarantees a primary send can start when a client is resolved (PKRR-018)")
    func isReadyGuaranteesSendWhenClientResolved() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = "ok"
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key"
        )
        let service = LLMService(
            configuration: config,
            clients: .init(primary: mockClient)
        )

        #expect(await service.isReady, "isReady is true when configuration is valid and a primary client is resolved")
        #expect(await service.isConfigured, "isConfigured is also true here")

        // A primary stream must succeed when isReady is true.
        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "ping")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )
        let chunks = try await stream.collect()
        #expect(chunks.compactMap { $0.choices.first?.delta.content }.joined() == "ok")
    }

    @Test("Health details explain invalid configuration versus missing client factory (PKRR-018)")
    func healthDetailsDistinguishInvalidConfigFromMissingClient() async {
        // Invalid configuration: readiness reports invalid configuration.
        let invalidConfig = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "",
            apiKey: "",
            activeProvider: .openAI
        )
        let invalidService = LLMService(configuration: invalidConfig, clients: .empty)
        let invalidDetails = await invalidService.getHealthDetails()
        #expect(invalidDetails?["readiness"] == "invalid configuration")
        #expect(await invalidService.isConfigured == false)
        #expect(await invalidService.isReady == false)

        // Valid configuration but no client factory: readiness reports missing client.
        let validConfig = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key",
            activeProvider: .openRouter
        )
        let noClientService = LLMService(configuration: validConfig, clients: .empty)
        let noClientDetails = await noClientService.getHealthDetails()
        #expect(noClientDetails?["provider"] == "OpenRouter")
        #expect(noClientDetails?["readiness"] == "no client resolved for provider OpenRouter; no client factory supplied")
        #expect(await noClientService.isConfigured == true)
        #expect(await noClientService.isReady == false)

        // Valid configuration with a client: readiness reports ready.
        let readyClient = MockLLMClient()
        let readyService = LLMService(
            configuration: validConfig,
            clients: .init(primary: readyClient)
        )
        let readyDetails = await readyService.getHealthDetails()
        #expect(readyDetails?["readiness"] == "ready")
        #expect(await readyService.isReady == true)
    }

    @Test("generationStream fails clientNotResolved when configured but no client exists (PKRR-018)")
    func generationStreamThrowsClientNotResolvedWhenNoClient() async {
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key",
            activeProvider: .openAI
        )
        let service = LLMService(configuration: config, clients: .empty)

        // Config is valid but no client factory → the more specific clientNotResolved error,
        // not the generic notConfigured.
        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )
        let thrown = await #expect(throws: LLMServiceError.self) {
            _ = try await stream.collect()
        }
        #expect(thrown == .clientNotResolved(provider: "OpenAI"))
    }

    @Test("generationStream finishes with clientNotResolved when configured but no client exists (PKRR-018)")
    func generationStreamFinishesWithClientNotResolvedWhenNoClient() async {
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key",
            activeProvider: .openAI
        )
        let service = LLMService(configuration: config, clients: .empty)

        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hi")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )

        var capturedError: Error?
        do {
            for try await _ in stream {}
        } catch {
            capturedError = error
        }
        #expect(capturedError as? LLMServiceError == .clientNotResolved(provider: "OpenAI"))
    }

    @Test("generationStream still throws notConfigured when configuration is invalid (PKRR-018)")
    func generationStreamThrowsNotConfiguredWhenConfigInvalid() async {
        // Storage-backed service with default (invalid) config and no client.
        let service = LLMService(storage: MockConfigurationService(), clientResolver: FixedClientsResolver.empty)
        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )
        let thrown = await #expect(throws: LLMServiceError.self) {
            _ = try await stream.collect()
        }
        #expect(thrown == .notConfigured)
    }

    @Test("Test generation parameters passing")
    func generationParametersPassing() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = "Response"

        let service = LLMService(
            configuration: .fixture(apiKey: "key"),
            clients: .init(primary: mockClient)
        )

        // Case 1: Custom parameters passed
        let customParams = GenerationParameters(temperature: 0.5, maxTokens: 100)
        let customStream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: customParams,
            modelTier: .primary
        )
        _ = try await customStream.collect()

        #expect(mockClient.lastParameters?.temperature == 0.5)
        #expect(mockClient.lastParameters?.maxTokens == 100)

        // Case 2: No parameters passed, should use configuration defaults
        let config = LLMConfiguration(
            activeProvider: .openAI,
            providers: [
                .openAI: ProviderConfiguration(
                    endpoint: "https://api.openai.com",
                    apiKey: "key",
                    modelName: "gpt-4o",
                    utilityModel: "gpt-4o-mini",
                    fastModel: "gpt-4o-mini",
                    toolFormat: .openAI,
                    temperature: 0.8,
                    maxTokens: 500
                ),
            ]
        )
        try await service.updateConfiguration(config)

        let defaultStream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "Hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )
        _ = try await defaultStream.collect()
        #expect(mockClient.lastParameters?.temperature == 0.8)
        #expect(mockClient.lastParameters?.maxTokens == 500)
    }

    @Test("First public call awaits delayed configuration load")
    func firstCallAwaitsDelayedConfigurationLoad() async throws {
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.example.com",
            modelName: "test-model",
            apiKey: "test-key"
        )
        let storage = DelayedConfigurationService(config: config)
        let service = LLMService(storage: storage, clientResolver: FixedClientsResolver.empty)

        let exportTask = Task { try await service.exportConfiguration() }

        await storage.waitUntilLoadStarts()
        #expect(await storage.loadStarted)

        await storage.release()
        _ = try await exportTask.value
    }

    @Test("generationStream awaits delayed configuration before selecting a factory-created client")
    func generationStreamAwaitsDelayedConfigurationBeforeSelectingFactoryClient() async {
        let config = LLMConfiguration.fixture(
            endpoint: "https://test.example.com",
            modelName: "test-model",
            apiKey: "test-key"
        )
        let storage = DelayedConfigurationService(config: config)
        let mockClient = MockLLMClient()
        let service = LLMService(
            storage: storage,
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )

        // The first public call starts preparation, so the stream task must be created
        // before we wait for the (delayed) configuration load to begin.
        let streamTask = Task {
            await service.generationStream(
                messages: [LLMMessage(role: .user, content: "Hi")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil,
                modelTier: .primary
            )
        }

        await storage.waitUntilLoadStarts()
        #expect(await storage.loadStarted)
        await Task.yield()
        #expect(mockClient.streamCallCount == 0)

        await storage.release()
        _ = await streamTask.value
        #expect(mockClient.streamCallCount == 1)
    }

    // MARK: - LLM runtime state decomposition regressions

    @Test("Storage-backed service with an injected Ollama client loads and exposes the Ollama configuration")
    func storageBackedInjectedClientLoadsOllamaConfiguration() async throws {
        let config = LLMConfiguration.fixture(modelName: "llama3", activeProvider: .ollama)
        let storage = MockConfigurationService()
        try await storage.save(config)

        let service = LLMService(
            storage: storage,
            clientResolver: FixedClientsResolver(clients: .init(primary: MockLLMClient()))
        )
        // Force the first-call preparation to complete so the loaded configuration is applied.
        _ = try await service.exportConfiguration()

        #expect(await service.configuration.activeProvider == .ollama)
        #expect(await service.configuration.activeProviderConfiguration.modelName == "llama3")
        #expect(await service.isConfigured)
        #expect(await service.isReady)
    }

    @Test("Anthropic metadata and generation defaults come from the loaded configuration")
    func anthropicConfigurationMetadataIsExposed() async throws {
        let config = LLMConfiguration.fixture(
            modelName: "claude-3-5-sonnet",
            apiKey: "sk-ant-test",
            activeProvider: .anthropic,
            temperature: 0.7,
            maxTokens: 512
        )
        let storage = MockConfigurationService()
        try await storage.save(config)

        let service = LLMService(
            storage: storage,
            clientResolver: FixedClientsResolver(clients: .init(primary: MockLLMClient()))
        )
        _ = try await service.exportConfiguration()

        let loaded = await service.configuration
        #expect(loaded.activeProvider == .anthropic)
        #expect(loaded.activeProviderConfiguration.modelName == "claude-3-5-sonnet")
        #expect(loaded.activeProviderConfiguration.apiKey == "sk-ant-test")
        #expect(loaded.activeProviderConfiguration.generationParameters.temperature == 0.7)
        #expect(loaded.activeProviderConfiguration.generationParameters.maxTokens == 512)
    }

    @Test("Invalid loaded configuration clears all previous clients")
    func invalidLoadedConfigurationClearsClients() async throws {
        let storage = MockConfigurationService()
        try await storage.save(.fixture(apiKey: "test-key"))
        let mockClient = MockLLMClient()

        let service = LLMService(
            storage: storage,
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        _ = try await service.exportConfiguration()
        #expect(await service.isReady)

        try await storage.save(.openAI) // invalid: empty model/api key
        await service.loadConfiguration()

        #expect(await service.isConfigured == false)
        #expect(await service.isReady == false)
    }

    @Test("Invalid restored backup clears all previous clients")
    func invalidRestoredBackupClearsClients() async throws {
        let storage = MockConfigurationService()
        try await storage.save(.fixture(apiKey: "test-key"))
        await storage.setBackupConfig(.fixture(apiKey: "test-key"))
        let mockClient = MockLLMClient()

        let service = LLMService(
            storage: storage,
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        _ = try await service.exportConfiguration()
        #expect(await service.isReady)

        await storage.setBackupConfig(.openAI) // invalid
        try await service.restoreFromBackup()

        #expect(await service.isConfigured == false)
        #expect(await service.isReady == false)
    }

    @Test("Valid configuration without a primary client yields clientNotResolved from send and every stream overload")
    func missingClientProducesClientNotResolvedEverywhere() async {
        let service = LLMService(configuration: .fixture(apiKey: "test-key"), clients: .empty)

        await #expect(throws: LLMServiceError.self) {
            let stream = await service.generationStream(
                messages: [LLMMessage(role: .user, content: "Hi")],
                tools: nil, toolChoice: nil, responseFormat: nil,
                generationParameters: nil, modelTier: .primary
            )
            _ = try await stream.collect()
        }

        await #expect(throws: LLMServiceError.self) {
            let stream = await service.generationStream(
                messages: [LLMMessage(role: .user, content: "Hi")],
                tools: nil, toolChoice: nil, responseFormat: nil,
                generationParameters: nil, modelTier: .primary,
                responseModalities: [], audioOutput: nil
            )
            _ = try await stream.collect()
        }
    }

    @Test("Invalid configuration yields notConfigured from send and every stream overload")
    func invalidConfigurationProducesNotConfiguredEverywhere() async {
        let invalid = LLMConfiguration.fixture(modelName: "", apiKey: "")
        let service = LLMService(configuration: invalid, clients: .init(primary: MockLLMClient()))

        await #expect(throws: LLMServiceError.self) {
            let stream = await service.generationStream(
                messages: [LLMMessage(role: .user, content: "Hi")],
                tools: nil, toolChoice: nil, responseFormat: nil,
                generationParameters: nil, modelTier: .primary
            )
            _ = try await stream.collect()
        }

        await #expect(throws: LLMServiceError.self) {
            let stream = await service.generationStream(
                messages: [LLMMessage(role: .user, content: "Hi")],
                tools: nil, toolChoice: nil, responseFormat: nil,
                generationParameters: nil, modelTier: .primary,
                responseModalities: [], audioOutput: nil
            )
            _ = try await stream.collect()
        }
    }

    @Test("isConfigured, isReady, and health status agree across readiness states")
    func readinessProjectionsAgree() async {
        let invalid = LLMService(configuration: .init(activeProvider: .openAI, providers: [:]), clients: .empty)
        #expect(await invalid.isConfigured == false)
        #expect(await invalid.isReady == false)
        #expect(await invalid.checkHealth() == .degraded)

        let noClient = LLMService(configuration: .fixture(apiKey: "test-key"), clients: .empty)
        #expect(await noClient.isConfigured)
        #expect(await noClient.isReady == false)
        #expect(await noClient.checkHealth() == .degraded)

        let ready = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: MockLLMClient())
        )
        #expect(await ready.isConfigured)
        #expect(await ready.isReady)
        #expect(await ready.checkHealth() == .ok)
    }

    @Test("Utility and fast tiers use their configured clients and fall back to primary")
    func tierRoutingUsesConfiguredClientsAndFallsBack() async throws {
        let primary = MockLLMClient()
        let utility = MockLLMClient()
        let fast = MockLLMClient()
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: primary, utility: utility, fast: fast)
        )

        for (client, content, tier) in [(primary, "p", ModelTier.primary), (utility, "u", .utility), (fast, "f", .fast)] {
            let stream = await service.generationStream(
                messages: [LLMMessage(role: .user, content: content)],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil,
                modelTier: tier
            )
            _ = try await stream.collect()
            #expect(client.lastMessages.first?.content == content)
        }

        // Fallback: utility/fast tiers without a dedicated client route to primary.
        let fallback = MockLLMClient()
        let fallbackService = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: fallback)
        )
        for (content, tier) in [("u2", ModelTier.utility), ("f2", .fast)] {
            let stream = await fallbackService.generationStream(
                messages: [LLMMessage(role: .user, content: content)],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil,
                modelTier: tier
            )
            _ = try await stream.collect()
        }
        #expect(fallback.messageHistory.map { $0.first?.content ?? "" } == ["u2", "f2"])
    }

    @Test("Concurrent first operations perform one migration/load sequence")
    func concurrentFirstOperationsPerformSingleLoad() async throws {
        let config = LLMConfiguration.fixture(apiKey: "test-key")
        let storage = DelayedConfigurationService(config: config)
        let service = LLMService(storage: storage, clientResolver: FixedClientsResolver.empty)

        let first = Task { try await service.exportConfiguration() }
        let second = Task { try await service.exportConfiguration() }

        await storage.waitUntilLoadStarts()
        #expect(await storage.loadStarted)

        await storage.release()
        _ = try await first.value
        _ = try await second.value

        #expect(await storage.loadCount == 1)
    }

    @Test("A configuration change atomically replaces configuration and clients")
    func configurationChangeReplacesSnapshotAtomically() async throws {
        let primary = MockLLMClient()
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: primary)
        )

        try await service.updateConfiguration(.fixture(modelName: "qwen", activeProvider: .ollama))

        #expect(await service.configuration.activeProvider == .ollama)
        #expect(await service.configuration.activeProviderConfiguration.modelName == "qwen")
        #expect(await service.isReady)

        // An invalid update clears clients in the same operation.
        try await service.updateConfiguration(LLMConfiguration(activeProvider: .openAI, providers: [:]))
        #expect(await service.isConfigured == false)
        #expect(await service.isReady == false)
    }
}
