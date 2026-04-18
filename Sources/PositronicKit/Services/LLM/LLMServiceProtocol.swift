import Foundation
import PKPrompt
import PKShared
import OpenAI

// MARK: - Request / Result Types

/// Groups the parameters for a high-level LLM chat stream request.
public struct LLMChatRequest: Sendable {
    public let userQuery: String
    public let contextNotes: [ContextFile]
    public let memories: [Memory]
    public let chatHistory: [Message]
    public let tools: [AnyTool]
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let clientName: String?
    public let systemInstructions: String?
    public let structuredOutput: StructuredOutputRequest?
    public let responseFormat: ChatQuery.ResponseFormat?
    public let generationParameters: GenerationParameters?
    public let useFastModel: Bool

    public init(
        userQuery: String,
        contextNotes: [ContextFile] = [],
        memories: [Memory] = [],
        chatHistory: [Message],
        tools: [AnyTool],
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        clientName: String?,
        systemInstructions: String? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        generationParameters: GenerationParameters? = nil,
        useFastModel: Bool = false
    ) {
        self.userQuery = userQuery
        self.contextNotes = contextNotes
        self.memories = memories
        self.chatHistory = chatHistory
        self.tools = tools
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.clientName = clientName
        self.systemInstructions = systemInstructions
        self.structuredOutput = structuredOutput
        self.responseFormat = nil
        self.generationParameters = generationParameters
        self.useFastModel = useFastModel
    }

    @available(*, deprecated, message: "Use structuredOutput for structured generation requests.")
    public init(
        userQuery: String,
        contextNotes: [ContextFile] = [],
        memories: [Memory] = [],
        chatHistory: [Message],
        tools: [AnyTool],
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        clientName: String?,
        systemInstructions: String? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        useFastModel: Bool = false
    ) {
        self.userQuery = userQuery
        self.contextNotes = contextNotes
        self.memories = memories
        self.chatHistory = chatHistory
        self.tools = tools
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.clientName = clientName
        self.systemInstructions = systemInstructions
        self.structuredOutput = structuredOutput
        self.responseFormat = responseFormat
        self.generationParameters = generationParameters
        self.useFastModel = useFastModel
    }
}

/// The result of a high-level LLM chat stream request.
public struct LLMStreamResult: Sendable {
    public let stream: AsyncThrowingStream<ChatStreamResult, Error>
    public let rawPrompt: String

    public init(
        stream: AsyncThrowingStream<ChatStreamResult, Error>,
        rawPrompt: String
    ) {
        self.stream = stream
        self.rawPrompt = rawPrompt
    }
}

/// The result of building a prompt (messages + debug info).
public struct LLMPromptResult: Sendable {
    public let messages: [ChatQuery.ChatCompletionMessageParam]
    public let rawPrompt: String

    public init(
        messages: [ChatQuery.ChatCompletionMessageParam],
        rawPrompt: String
    ) {
        self.messages = messages
        self.rawPrompt = rawPrompt
    }
}

/// Groups the parameters for building a prompt or context.
public struct LLMPromptRequest: Sendable {
    public let userQuery: String
    public let contextNotes: [ContextFile]
    public let memories: [Memory]
    public let chatHistory: [Message]
    public let tools: [AnyTool]
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let clientName: String?
    public let systemInstructions: String?
    public let generationParameters: GenerationParameters?

    public init(
        userQuery: String,
        contextNotes: [ContextFile] = [],
        memories: [Memory] = [],
        chatHistory: [Message],
        tools: [AnyTool],
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        clientName: String?,
        systemInstructions: String? = nil,
        generationParameters: GenerationParameters? = nil
    ) {
        self.userQuery = userQuery
        self.contextNotes = contextNotes
        self.memories = memories
        self.chatHistory = chatHistory
        self.tools = tools
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.clientName = clientName
        self.systemInstructions = systemInstructions
        self.generationParameters = generationParameters
    }
}

/// Parsed endpoint components.
public struct EndpointComponents: Sendable {
    public let host: String
    public let port: Int
    public let scheme: String

    public init(host: String, port: Int, scheme: String) {
        self.host = host
        self.port = port
        self.scheme = scheme
    }
}

// MARK: - Protocol

/// Protocol for LLM Service to enable mocking and isolation
public protocol LLMServiceProtocol: HealthCheckable, Sendable {
    var isConfigured: Bool { get async }
    var configuration: LLMConfiguration { get async }

    // Configuration Management
    func loadConfiguration() async
    func updateConfiguration(_ config: LLMConfiguration) async throws
    func clearConfiguration() async
    func restoreFromBackup() async throws
    func exportConfiguration() async throws -> Data
    func importConfiguration(from data: Data) async throws

    // Core LLM Interaction
    func sendMessage(_ content: String) async throws -> String
    func sendMessage(
        _ content: String,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool
    ) async throws -> String

    func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult

    /// Stream chat response from a prepared list of messages (low-level)
    func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]?,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?,
        responseFormat: ChatQuery.ResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool,
        useFastModel: Bool
    ) async -> AsyncThrowingStream<ChatStreamResult, Error>

    // Utilities
    func generateTags(for text: String) async throws -> [String]
    func generateTitle(for messages: [Message]) async throws -> String
    func evaluateRecallPerformance(transcript: String, recalledMemories: [Memory]) async throws
        -> [String: Double]
    func fetchAvailableModels() async throws -> [String]?
}

public extension LLMServiceProtocol {
    func chatStream(
        messages: [ChatQuery.ChatCompletionMessageParam],
        tools: [ChatQuery.ChatCompletionToolParam]? = nil,
        toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil,
        responseFormat: ChatQuery.ResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false,
        useFastModel: Bool = false
    ) async -> AsyncThrowingStream<ChatStreamResult, Error> {
        await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            useUtilityModel: useUtilityModel,
            useFastModel: useFastModel
        )
    }
}
