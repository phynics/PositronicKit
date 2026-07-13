import Foundation
import Logging
import PKPrompt
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

private final class CapturingLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private struct CapturingLogHandler: LogHandler {
    let sink: CapturingLogSink
    var logLevel: Logger.Level = .debug
    var metadata = Logger.Metadata()

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        sink.append(message.description)
    }
}

private enum TestUtilityError: Error, PKError {
    case failure

    var errorDomain: String {
        PKErrorDomain.llm
    }

    var errorCode: Int {
        9999
    }

    var userFriendlyMessage: String {
        "Friendly utility failure"
    }
}

/// Storage that suspends `load()` until `release()` is called, so tests can observe whether the
/// first public call awaits the preparation task.
private actor DelayedConfigurationService: ConfigurationServiceProtocol {
    var config: LLMConfiguration
    private var loadContinuation: CheckedContinuation<LLMConfiguration, Never>?
    private(set) var loadStarted = false

    init(config: LLMConfiguration) {
        self.config = config
    }

    func load() async -> LLMConfiguration {
        loadStarted = true
        return await withCheckedContinuation { continuation in
            self.loadContinuation = continuation
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
        StructuredOutputAdapterRegistry.register(NativeJSONSchemaStructuredOutputAdapter(), for: .openAI)
        llmService = LLMService(storage: MockConfigurationService())
    }

    @Test("Test updating LLM configuration")
    func configurationUpdate() async throws {
        let config = LLMConfiguration(
            endpoint: "https://test.api.com",
            modelName: "test-model",
            apiKey: "test-key"
        )

        try await llmService.updateConfiguration(config)

        #expect(await llmService.isConfigured)
        #expect(await llmService.configuration.modelName == "test-model")
    }

    @Test("Test prompt building logic and structure")
    func promptBuilding() async throws {
        let contextFiles = [
            ContextFile(name: "Test Note", content: "Note Content", source: "note"),
        ]
        let history = [
            Message(content: "Previous user message", role: .user),
            Message(content: "Previous assistant message", role: .assistant),
        ]

        let prompt = try await PromptAssembler.assemble(
            LLMPromptRequest(
                userQuery: "Current question",
                contextNotes: contextFiles,
                memories: [],
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
        #expect(renderedPrompt.contains("Note Content"))
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
                contextNotes: [],
                memories: [],
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

    @Test("Test LLMService error when not configured")
    func unconfiguredServiceError() async throws {
        let service = LLMService(storage: MockConfigurationService())
        // No configuration provided

        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await service.sendMessage("Hello")
        }
    }

    @Test("Test generateTitle method")
    func titleGeneration() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = #"{"title":"SwiftUI Basics"}"#

        let service = LLMService(storage: MockConfigurationService(), client: mockClient) // Inject mock transport directly for focused testing.

        let messages = [
            Message(content: "How do I use SwiftUI?", role: .user),
            Message(content: "You use it by declaring views.", role: .assistant),
        ]

        let title = try await service.generateTitle(for: messages)
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
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)

        mockClient.nextResponse = #"{"tags":["Swift","Tests"]}"#
        let tags = try await service.generateTags(for: "Swift tests are great")
        #expect(tags == ["swift", "tests"])

        guard case let .jsonSchema(tagSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected generateTags to use a JSON schema response format")
            return
        }
        #expect(tagSchema.name == "llm_tags")
        let tagSchemaText = try String(decoding: JSONEncoder().encode(tagSchema.schema), as: UTF8.self)
        #expect(tagSchemaText.contains("\"tags\""))

        mockClient.nextResponse = #"{"title":"Condensed Title"}"#
        let title = try await service.generateTitle(for: [
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

        let firstMemory = try Memory(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            title: "First memory",
            content: "Useful detail"
        )
        let secondMemory = try Memory(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            title: "Second memory",
            content: "Off-topic detail"
        )

        mockClient.nextResponse = #"{"00000000-0000-0000-0000-000000000001":0.5,"00000000-0000-0000-0000-000000000002":-1.0}"#
        let scores = try await service.evaluateRecallPerformance(
            transcript: "Transcript text",
            recalledMemories: [firstMemory, secondMemory]
        )

        #expect(scores == [
            "00000000-0000-0000-0000-000000000001": 0.5,
            "00000000-0000-0000-0000-000000000002": -1.0,
        ])

        guard case let .jsonSchema(recallSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected evaluateRecallPerformance to use a JSON schema response format")
            return
        }
        #expect(recallSchema.name == "recall_performance")
        let recallSchemaText = try String(decoding: JSONEncoder().encode(recallSchema.schema), as: UTF8.self)
        #expect(recallSchemaText.contains("\"additionalProperties\""))
        #expect(recallSchemaText.contains("\"minimum\":-1"))
        #expect(recallSchemaText.contains("\"maximum\":1"))
    }

    @Test("Utility generations return defaults and log friendly failure messages")
    func utilityGenerationsReturnDefaultsAndLogFriendlyFailureMessages() async throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.llm.utilities") { _ in
            CapturingLogHandler(sink: sink)
        }

        let mockClient = MockLLMClient()
        mockClient.shouldThrowError = true
        mockClient.errorToThrow = TestUtilityError.failure

        let service = LLMService(
            storage: MockConfigurationService(),
            client: mockClient,
            logger: logger
        )

        let tags = try await service.generateTags(for: "Tag this text")
        #expect(tags.isEmpty)

        let title = try await service.generateTitle(for: [
            Message(content: "A conversation", role: .user),
        ])
        #expect(title == "New Conversation")

        let recall = try await service.evaluateRecallPerformance(
            transcript: "Transcript text",
            recalledMemories: [
                Memory(title: "Memory", content: "Content"),
            ]
        )
        #expect(recall.isEmpty)

        let messages = sink.all()
        #expect(messages.contains(where: { $0.contains("Friendly utility failure") }))
        #expect(messages.contains(where: { $0.contains("Failed to generate tags") }))
        #expect(messages.contains(where: { $0.contains("Failed to generate title") }))
        #expect(messages.contains(where: { $0.contains("Failed to evaluate recall") }))
    }

    @Test("Health details report typed provider identity, not endpoint substrings")
    func healthDetailsUseTypedProvider() async {
        let openRouterConfig = LLMConfiguration(
            endpoint: "https://my-proxy.example.com/v1",
            modelName: "gpt-4o",
            apiKey: "test-key",
            provider: .openRouter
        )
        let service = LLMService(configuration: openRouterConfig)

        let details = await service.getHealthDetails()
        #expect(details?["provider"] == "OpenRouter")
        #expect(details?["model"] == "gpt-4o")
    }

    @Test("Health check is degraded when not configured")
    func healthStatusDegradedWhenNotConfigured() async {
        let service = LLMService(storage: MockConfigurationService())
        let status = await service.checkHealth()
        #expect(status == .degraded)
    }

    @Test("Health check is degraded when configured but no client exists")
    func healthCheckDegradedWhenNoClient() async {
        // LLMService init with a valid config creates a client via the registry,
        // but if the registry has no factory for that provider, the client is nil.
        // Use a storage-backed init with no client to exercise this path.
        let mockStorage = MockConfigurationService()
        let service = LLMService(storage: mockStorage, client: nil, utilityClient: nil, fastClient: nil)
        let status = await service.checkHealth()
        #expect(status == .degraded)
    }

    @Test("Health check is ok when configured client responds")
    func healthCheckOkWhenClientReachable() async {
        let mockClient = MockLLMClient()
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        let status = await service.checkHealth()
        #expect(status == .ok)
    }

    @Test("Test generation parameters passing")
    func generationParametersPassing() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = "Response"

        let service = LLMService(storage: MockConfigurationService(), client: mockClient)

        // Case 1: Custom parameters passed
        let customParams = GenerationParameters(temperature: 0.5, maxTokens: 100)
        _ = try await service.sendMessage("Hello", responseFormat: nil, generationParameters: customParams, useUtilityModel: false)

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
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        _ = try await service.sendMessage("Hello")
        #expect(mockClient.lastParameters?.temperature == 0.8)
        #expect(mockClient.lastParameters?.maxTokens == 500)
    }

    @Test("Preparation task is assigned synchronously during init")
    func preparationTaskAssignedDuringInit() {
        let config = LLMConfiguration(
            endpoint: "https://test.example.com",
            modelName: "test-model",
            apiKey: "test-key"
        )
        let storage = DelayedConfigurationService(config: config)
        let service = LLMService(storage: storage)

        #expect(service.hasPreparationTask)
    }

    @Test("First public call awaits delayed configuration load")
    func firstCallAwaitsDelayedConfigurationLoad() async throws {
        let config = LLMConfiguration(
            endpoint: "https://test.example.com",
            modelName: "test-model",
            apiKey: "test-key"
        )
        let storage = DelayedConfigurationService(config: config)
        let service = LLMService(storage: storage)

        let exportTask = Task { try await service.exportConfiguration() }

        // The preparation task should reach storage.load() well within this window.
        for _ in 0 ..< 50 {
            if await storage.loadStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await storage.loadStarted)

        await storage.release()
        _ = try await exportTask.value
    }
}
