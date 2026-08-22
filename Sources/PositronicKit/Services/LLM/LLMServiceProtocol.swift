import Foundation
import PKPrompt
import PKContracts
import PKUtilities

// MARK: - Request / Result Types

/// Groups the parameters for a high-level LLM generation stream request.
public struct LLMGenerationRequest: Sendable {
    public let userQuery: String
    public let contextNotes: [ContextNote]
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
        contextNotes: [ContextNote] = [],
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
/// ``LLMStreamClient/generationStream(messages:tools:toolChoice:responseFormat:generationParameters:modelTier:)``.
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

/// The result of a high-level LLM generation stream request.
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
    /// Used by `TurnEngine` to inject the sidecar directive instruction block.
    public let turnInstructions: String?
    public let contextNotes: [ContextNote]
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
        contextNotes: [ContextNote] = [],
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
        contextNotes: [ContextNote] = [],
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

/// Streaming generation seam: a consumer that drives LLM generation by streaming
/// completions. This is the narrowest seam the runtime turn loop needs.
public protocol LLMStreamClient: Sendable {
    var isConfigured: Bool { get async }
    var configuration: LLMConfiguration { get async }

    /// Returns the structured-output preparation behavior for the selected model tier.
    func structuredOutputAdapter(for modelTier: ModelTier) async -> any StructuredOutputAdapter

    func generationStreamWithContext(_ request: LLMGenerationRequest) async throws -> LLMStreamResult

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
    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error>

    func generationStream(
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

/// Utility LLM task seam: one-shot message sends, best-effort tag/title generation, and
/// model listing. These are non-streaming helper tasks that some hosts drive independently
/// of the turn loop.
///
/// `bestEffortTags(for:)` and `bestEffortTitle(for:)` are explicitly best-effort: they never
/// throw, log failures, and return documented defaults. Hosts that own their own fallback
/// policy should use the strict ``LLMUtilityGenerator`` instead.
public protocol LLMUtilityClient: Sendable {
    func sendMessage(_ content: String) async throws -> String
    func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async throws -> String

    /// Generates tags/keywords for the given text, returning an empty array on failure.
    func bestEffortTags(for text: String) async -> [String]

    /// Generates a concise thread title, returning `"New Thread"` on failure.
    func bestEffortTitle(for messages: [Message]) async -> String

    func fetchAvailableModels() async throws -> [String]?
}

public extension LLMUtilityClient {
    /// Sends a one-shot message using the given model tier, defaulting to the primary model.
    func sendMessage(
        _ content: String,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier = .primary
    ) async throws -> String {
        try await sendMessage(
            content,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }
}

public extension LLMStreamClient {
    func structuredOutputAdapter(for modelTier: ModelTier) async -> any StructuredOutputAdapter {
        DefaultStructuredOutputAdapter()
    }

    func generationStream(
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
        return await generationStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }

    /// Default-args convenience for the low-level streaming entry point.
    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: LLMToolChoice? = nil,
        responseFormat: LLMResponseFormat? = nil,
        generationParameters: GenerationParameters? = nil,
        modelTier: ModelTier = .primary
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await generationStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }
}
