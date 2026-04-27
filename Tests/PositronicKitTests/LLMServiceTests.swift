@testable import PositronicKit
import PKPrompt
@testable import PKShared
import PKTestSupport
import OpenAI
import Testing

@MainActor
struct LLMServiceTests {
    private let llmService: LLMService

    init() {
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
        if let first = messages.first, case .system = first {
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
            if case let .user(m) = msg, case let .string(content) = m.content {
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
            if case let .assistant(m) = msg, let contentWrap = m.content, case let .textContent(content) = contentWrap {
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

        if case let .user(m) = lastMessage, case let .string(content) = m.content {
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

        if let first = messages.first, case let .system(s) = first, case let .textContent(content) = s.content {
            #expect(content.contains("System Only"))
        } else {
            #expect(Bool(false), "First message should be system")
        }

        if let last = messages.last, case let .user(u) = last, case let .string(content) = u.content {
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
        mockClient.nextResponse = "SwiftUI Basics"

        let service = LLMService(storage: MockConfigurationService(), client: mockClient) // Use client directly if possible or utilityClient

        let messages = [
            Message(content: "How do I use SwiftUI?", role: .user),
            Message(content: "You use it by declaring views.", role: .assistant),
        ]

        let title = try await service.generateTitle(for: messages)
        #expect(title == "SwiftUI Basics")

        // Verify transcript was sent in the prompt
        if let lastMessage = mockClient.lastMessages.last {
            if case let .user(m) = lastMessage, case let .string(content) = m.content {
                #expect(content.contains("How do I use SwiftUI?"))
                #expect(content.contains("You use it by declaring views."))
            }
        }
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
                )
            ]
        )
        try await service.updateConfiguration(config)
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        _ = try await service.sendMessage("Hello")
        #expect(mockClient.lastParameters?.temperature == 0.8)
        #expect(mockClient.lastParameters?.maxTokens == 500)
    }
}
