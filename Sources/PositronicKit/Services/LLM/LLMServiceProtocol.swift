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
    public let modelTier: ModelTier

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
        modelTier: ModelTier = .primary
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
        self.modelTier = modelTier
    }
}

/// Selects which configured model tier a streaming request should target.
///
/// Replaces the former `useUtilityModel`/`useFastModel` boolean pair on
/// ``LLMStreamClient/chatStream(messages:tools:toolChoice:responseFormat:generationParameters:modelTier:)``.
/// Exactly one tier is selected per call — the previous booleans were ambiguous when both were
/// `true` (the implementation checked `useFastModel` first, then `useUtilityModel`, then fell
/// through to the primary client) and didn't document that precedence. `ModelTier` makes the
/// selection exhaustive and self-documenting.
public enum ModelTier: Sendable, Equatable {
    /// The primary (default) model — the main client. This is the default tier.
    case primary
    /// The utility model — lightweight tasks (tag/title generation, recall evaluation).
    /// Falls back to the primary client if no utility client is configured.
    case utility
    /// The fast model — lower-latency variant, if configured.
    /// Falls back to the primary client if no fast client is configured.
    case fast
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

    /// Stream chat response from a prepared list of messages (low-level).
    ///
    /// - Parameters:
    ///   - messages: The prepared message history to send.
    ///   - tools: Tool definitions to offer the model, if any.
    ///   - toolChoice: How the model should select among `tools`, if constrained.
    ///   - responseFormat: The expected response shape, if structured output is requested.
    ///   - generationParameters: Sampling/generation overrides for this request.
    ///   - modelTier: Which configured model tier to stream from (`.primary`, `.utility`,
    ///     or `.fast`). See ``ModelTier`` for the fallback rules when a tier's client isn't
    ///     configured.
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
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

public extension LLMStreamClient {
    /// Default-args convenience for the low-level streaming entry point.
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }
}
