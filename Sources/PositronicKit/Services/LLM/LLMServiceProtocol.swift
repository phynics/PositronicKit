import Foundation
import PKPrompt
import PKShared
import PKUtilities

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

/// The clients available for the configured model tiers.
public struct LLMClientSet: Sendable {
    /// The client used for ordinary chat requests.
    public let primary: (any LLMClientProtocol)?
    /// The client used for lightweight utility requests.
    public let utility: (any LLMClientProtocol)?
    /// The client used for latency-sensitive requests.
    public let fast: (any LLMClientProtocol)?

    /// Creates a set of clients for the available model tiers.
    ///
    /// - Parameters:
    ///   - primary: The ordinary chat client.
    ///   - utility: An optional lightweight utility client.
    ///   - fast: An optional latency-sensitive client.
    public init(
        primary: (any LLMClientProtocol)?,
        utility: (any LLMClientProtocol)? = nil,
        fast: (any LLMClientProtocol)? = nil
    ) {
        self.primary = primary
        self.utility = utility
        self.fast = fast
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
    public let userContent: MessageContent
    public var userQuery: String { userContent.text }
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
        userContent = MessageContent(userQuery)
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

    /// Creates a prompt request with ordered multimodal user content.
    public init(
        userContent: MessageContent,
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
        self.userContent = userContent
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

/// The complete language-model capability required by the PositronicKit facade.
/// Hosts inject one provider-selected value at their composition root.
public protocol LanguageModel: LLMStreamClient, LLMConfigStore, LLMUtilityClient {}

struct AnyLanguageModel: LanguageModel {
    let base: any LLMStreamClient & LLMConfigStore & LLMUtilityClient

    var isConfigured: Bool { get async { await base.isConfigured } }
    var configuration: LLMConfiguration { get async { await base.configuration } }
    func chatStreamWithContext(_ request: LLMChatRequest) async throws -> LLMStreamResult {
        try await base.chatStreamWithContext(request)
    }
    func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, modelTier: ModelTier) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await base.chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier)
    }
    func chatStream(messages: [LLMMessage], tools: [LLMToolDefinition]?, toolChoice: LLMToolChoice?, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, modelTier: ModelTier, responseModalities: Set<ResponseModality>, audioOutput: AudioOutputOptions?) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await base.chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier, responseModalities: responseModalities, audioOutput: audioOutput)
    }
    func loadConfiguration() async { await base.loadConfiguration() }
    func updateConfiguration(_ config: LLMConfiguration) async throws { try await base.updateConfiguration(config) }
    func clearConfiguration() async { await base.clearConfiguration() }
    func restoreFromBackup() async throws { try await base.restoreFromBackup() }
    func exportConfiguration() async throws -> Data { try await base.exportConfiguration() }
    func importConfiguration(from data: Data) async throws { try await base.importConfiguration(from: data) }
    func sendMessage(_ content: String) async throws -> String { try await base.sendMessage(content) }
    func sendMessage(_ content: String, responseFormat: LLMResponseFormat?, generationParameters: GenerationParameters?, useUtilityModel: Bool) async throws -> String {
        try await base.sendMessage(content, responseFormat: responseFormat, generationParameters: generationParameters, useUtilityModel: useUtilityModel)
    }
    func generateTags(for text: String) async throws -> [String] { try await base.generateTags(for: text) }
    func generateTitle(for messages: [Message]) async throws -> String { try await base.generateTitle(for: messages) }
    func evaluateRecallPerformance(transcript: String, recalledMemories: [Memory]) async throws -> [String: Double] {
        try await base.evaluateRecallPerformance(transcript: transcript, recalledMemories: recalledMemories)
    }
    func fetchAvailableModels() async throws -> [String]? { try await base.fetchAvailableModels() }
}

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

    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
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
    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        guard !responseModalities.contains(.audio), audioOutput == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MultimodalContentError.missingCapability(.audioOutput))
            }
        }
        return await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }

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
