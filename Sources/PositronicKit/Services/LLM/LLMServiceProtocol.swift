import Foundation
import PKPrompt
import PKShared

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
    public let requestOriginName: String?
    public let systemInstructions: String?
    public let structuredOutput: StructuredOutputRequest?
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
        requestOriginName: String?,
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
        self.requestOriginName = requestOriginName
        self.systemInstructions = systemInstructions
        self.structuredOutput = structuredOutput
        self.generationParameters = generationParameters
        self.useFastModel = useFastModel
    }
}

/// The result of a high-level LLM chat stream request.
public struct LLMStreamResult: Sendable {
    public let stream: AsyncThrowingStream<LLMStreamChunk, Error>
    public let rawPrompt: String

    public init(
        stream: AsyncThrowingStream<LLMStreamChunk, Error>,
        rawPrompt: String
    ) {
        self.stream = stream
        self.rawPrompt = rawPrompt
    }
}

/// The result of building a prompt (messages + debug info).
public struct LLMPromptResult: Sendable {
    public let messages: [LLMMessage]
    public let rawPrompt: String

    public init(
        messages: [LLMMessage],
        rawPrompt: String
    ) {
        self.messages = messages
        self.rawPrompt = rawPrompt
    }
}

/// Groups the parameters for building a prompt or context.
public struct LLMPromptRequest: Sendable {
    public let userQuery: String
    /// Per-turn instruction text rendered with the user query (final prompt section),
    /// NOT with system instructions, so the system prefix stays provider-cache-stable.
    /// Used by `ChatEngine` to inject the sidecar directive instruction block.
    public let turnInstructions: String?
    public let contextNotes: [ContextFile]
    public let memories: [Memory]
    public let chatHistory: [Message]
    public let tools: [AnyTool]
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let requestOriginName: String?
    public let systemInstructions: String?
    public let generationParameters: GenerationParameters?

    public init(
        userQuery: String,
        turnInstructions: String? = nil,
        contextNotes: [ContextFile] = [],
        memories: [Memory] = [],
        chatHistory: [Message],
        tools: [AnyTool],
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        requestOriginName: String?,
        systemInstructions: String? = nil,
        generationParameters: GenerationParameters? = nil
    ) {
        self.userQuery = userQuery
        self.turnInstructions = turnInstructions
        self.contextNotes = contextNotes
        self.memories = memories
        self.chatHistory = chatHistory
        self.tools = tools
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.requestOriginName = requestOriginName
        self.systemInstructions = systemInstructions
        self.generationParameters = generationParameters
    }
}

/// Parsed endpoint components.
// MARK: - Narrow LLM seams

/// Streaming chat seam: a consumer that drives LLM generation by streaming chat
/// completions. This is the narrowest seam the runtime turn loop needs.
public protocol LLMStreamClient: Sendable {
    var isConfigured: Bool { get async }
    var configuration: LLMConfiguration { get async }

    func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult

    /// Stream chat response from a prepared list of messages (low-level)
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool,
        useFastModel: Bool
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error>
}

/// Configuration lifecycle seam: load, update, clear, back up, and transfer an LLM
/// service's configuration. Consumers that only manage provider settings depend on this
/// rather than the full LLM surface.
public protocol LLMConfigStore: Sendable {
    func loadConfiguration() async
    func updateConfiguration(_ config: LLMConfiguration) async throws
    func clearConfiguration() async
    func restoreFromBackup() async throws
    func exportConfiguration() async throws -> Data
    func importConfiguration(from data: Data) async throws
}

/// Utility LLM task seam: one-shot message sends, tag/title generation, recall
/// evaluation, and model listing. These are non-streaming helper tasks that some hosts
/// drive independently of the chat turn loop.
public protocol LLMUtilityClient: Sendable {
    func sendMessage(_ content: String) async throws -> String
    func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        useUtilityModel: Bool
    ) async throws -> String

    func generateTags(for text: String) async throws -> [String]
    func generateTitle(for messages: [Message]) async throws -> String
    func evaluateRecallPerformance(transcript: String, recalledMemories: [Memory]) async throws
        -> [String: Double]
    func fetchAvailableModels() async throws -> [String]?
}

// MARK: - Deprecated composite

/// Composite of the three narrow LLM seams plus `HealthCheckable`, retained for migration.
///
/// Prefer the narrow protocols (`LLMStreamClient`, `LLMConfigStore`, `LLMUtilityClient`)
/// directly. `LLMService` conforms to all three; new code should depend on the smallest seam
/// it needs. This typealias will be removed in a future release.
@available(*, deprecated, message: "Depend on LLMStreamClient, LLMConfigStore, or LLMUtilityClient directly; LLMService conforms to all three.")
public protocol LLMServiceProtocol: LLMStreamClient, LLMConfigStore, LLMUtilityClient, HealthCheckable {}

public extension LLMStreamClient {
    /// Default-args convenience for the low-level streaming entry point.
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        useUtilityModel: Bool = false,
        useFastModel: Bool = false
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
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
