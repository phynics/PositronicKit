import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Errors thrown by `ChatEngine` during setup and execution.
enum ChatEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput
    case streamTimedOut(TimeInterval)
    case danglingToolCall(id: String)
    case danglingToolResult(id: String)
    case duplicateSendId(UUID)
    case promptHistoryInconsistent(String)

    var errorDomain: String {
        PKErrorDomain.chat
    }

    var errorCode: Int {
        switch self {
        case .llmServiceNotConfigured: return 9001
        case .missingInput: return 9002
        case .streamTimedOut: return 9003
        case .danglingToolCall: return 9004
        case .danglingToolResult: return 9005
        case .duplicateSendId: return 9006
        case .promptHistoryInconsistent: return 9007
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .llmServiceNotConfigured:
            return "The LLM service is not configured. Please set up your API endpoint and key."
        case .missingInput:
            return "A message or tool outputs must be provided to start a chat turn."
        case let .streamTimedOut(timeout):
            return "The model stream did not finish within \(Self.timeoutDescription(timeout)). Please try again."
        case let .danglingToolCall(id):
            return "Conversation history contains an assistant tool call with id '\(id)' that has no matching tool result."
        case let .danglingToolResult(id):
            return "Conversation history contains a tool result with id '\(id)' that has no matching assistant tool call."
        case let .duplicateSendId(sendId):
            return "Turn \(sendId.uuidString.prefix(8)) has already been processed. Use a new sendId to start a new turn."
        case let .promptHistoryInconsistent(detail):
            return "The prompt history could not record this turn safely: \(detail)"
        }
    }

    var remediation: String? {
        switch self {
        case .danglingToolCall, .danglingToolResult:
            return "Repair the persisted conversation history so assistant tool calls and tool results are paired before retrying."
        case .duplicateSendId:
            return "The previous turn with this sendId completed successfully. Use a new sendId for a new turn, or if the previous attempt failed it is safe to retry with the same sendId."
        case .llmServiceNotConfigured, .missingInput, .streamTimedOut, .promptHistoryInconsistent:
            return nil
        }
    }

    private static func timeoutDescription(_ timeout: TimeInterval) -> String {
        if timeout.rounded() == timeout {
            return "\(Int(timeout)) seconds"
        }
        return "\(timeout) seconds"
    }
}

/// A required turn dependency failed during preparation.
enum TurnDegradationError: PKError {
    case required(TurnDiagnostic, Error)

    var diagnostic: TurnDiagnostic {
        switch self {
        case let .required(diagnostic, _): return diagnostic
        }
    }

    var errorDomain: String { PKErrorDomain.chat }
    var errorCode: Int { 9010 }
    var userFriendlyMessage: String {
        "Required \(diagnostic.dependency.rawValue) dependency failed during turn preparation: \(diagnostic.message)"
    }
}

/// Unified runtime turn orchestrator for both interactive chat and autonomous execution.
/// Returns `AsyncThrowingStream<ChatEvent>` for all use cases — callers decide how to consume.
///
/// `ChatEngine` is a thin coordinator: it validates preconditions, prepares the session
/// (context gathering, prompt assembly, prompt-history recording), and drives the ReAct
/// loop. Prompt follow-up synthesis (`PromptSnapshotBuilder`) and partial-assistant
/// persistence (`PartialAssistantPersistence`) remain delegated to focused standalone
/// helpers. Session preparation lives in `ChatEngine+TurnPreparation.swift`; the ReAct
/// loop lives in `ChatEngine+TurnLoop.swift`.
///
/// It is deliberately *not* the public customization surface for downstream applications;
/// external callers are expected to integrate through `PositronicKit` and the higher-level
/// extension protocols rather than depending on this concrete orchestrator directly.
struct ChatEngine {
    struct Dependencies {
        /// Production default for the per-stream idle watchdog. Callers must pass an explicit
        /// bounded value through `Dependencies` when they need to override it.
        static let defaultStreamTimeout: TimeInterval = 60

        let timelineManager: TimelineManager
        let agentInstanceStore: any AgentInstanceStoreProtocol
        let requestOriginStore: any RequestOriginStoreProtocol
        let messageStore: any MessageStoreProtocol
        /// Streaming chat seam: the runtime turn loop, `LLMStreamingStage`, and the
        /// `isConfigured`/`configuration` precondition checks depend only on this.
        let llmService: any LLMStreamClient
        /// Utility seam used solely by `ChatEngine.fetchContext` to generate RAG tags
        /// (`generateTags`). Kept separate from `llmService` so the streaming seam stays
        /// narrow; the facade and tests pass the same object for both (PKARCH-004 tension).
        let utilityClient: any LLMUtilityClient
        let toolRouter: ToolRouter
        let chatTurnPlugins: [any ChatTurnPlugin]
        let promptObserver: (any PromptObserving)?
        let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
        let loggingConfiguration: LoggingConfiguration
        let degradationPolicy: TurnDegradationPolicy
        let promptHistoryRegistry: TimelinePromptJournals
        let streamTimeout: TimeInterval

        init(
            timelineManager: TimelineManager,
            agentInstanceStore: any AgentInstanceStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            messageStore: any MessageStoreProtocol,
            llmService: any LLMStreamClient & LLMUtilityClient,
            toolRouter: ToolRouter,
            chatTurnPlugins: [any ChatTurnPlugin],
            promptObserver: (any PromptObserving)? = nil,
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
            loggingConfiguration: LoggingConfiguration = .default,
            degradationPolicy: TurnDegradationPolicy = .failRequired,
            promptHistoryRegistry: TimelinePromptJournals? = nil,
            streamTimeout: TimeInterval = Self.defaultStreamTimeout
        ) {
            self.timelineManager = timelineManager
            self.agentInstanceStore = agentInstanceStore
            self.requestOriginStore = requestOriginStore
            self.messageStore = messageStore
            self.llmService = llmService
            self.utilityClient = llmService
            self.toolRouter = toolRouter
            self.chatTurnPlugins = chatTurnPlugins
            self.promptObserver = promptObserver
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
            self.loggingConfiguration = loggingConfiguration
            self.degradationPolicy = degradationPolicy
            self.promptHistoryRegistry = promptHistoryRegistry ?? TimelinePromptJournals()
            self.streamTimeout = streamTimeout
        }
    }

    // MARK: - Constants

    enum Constants {
        static let sentinelToolName = "tool_call"
        static let defaultMaxTurns = 5
        static let maxRemoteDepth = 3
        /// Response tokens reserved for the model's output when the caller leaves
        /// `GenerationParameters.maxTokens` nil. Matches Anthropic's `defaultMaxTokens` and is a
        /// conservative default across providers.
        static let defaultOutputReserve = 4_096
        /// Extra tokens withheld from the context window for provider-side framing/overhead
        /// that is neither prompt nor response (e.g. message wrappers, tool-call scaffolding).
        static let providerOverhead = 512
    }

    let dependencies: Dependencies

    let logger = Logger.module(named: "chat-engine")

    var additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []

    // MARK: - Prompt Budget

    /// Derives a ``TokenBudget`` for prompt compression from the model's context window and the
    /// requested response output limit.
    ///
    /// The prompt budget is `contextWindowTokens - (maxOutputTokens ?? defaultOutputReserve)
    /// - providerOverhead` — the remaining context window after reserving space for the
    /// response. This deliberately does **not** infer context capacity from the output limit:
    /// a small `maxOutputTokens` (e.g. 512) no longer shrinks the whole prompt budget.
    ///
    /// - Parameters:
    ///   - contextWindowTokens: The model's full context-window size (from
    ///     `ProviderConfiguration.contextWindowTokens`).
    ///   - maxOutputTokens: The per-turn response output limit
    ///     (`GenerationParameters.maxTokens`). `nil` falls back to
    ///     ``Constants/defaultOutputReserve``.
    /// - Returns: A validated `TokenBudget` whose `availableTokens` is the prompt budget.
    /// - Throws: ``TokenBudgetError`` if the capacities are non-positive or the reserve
    ///   consumes the entire context window.
    static func makeTokenBudget(
        contextWindowTokens: Int,
        maxOutputTokens: Int?
    ) throws -> TokenBudget {
        let outputReserve = (maxOutputTokens ?? Constants.defaultOutputReserve) + Constants.providerOverhead
        return try TokenBudget(contextWindow: contextWindowTokens, outputReserve: outputReserve)
    }

    // MARK: - API

    /// Execute a chat turn and return a stream of deltas.
    /// - Parameters:
    ///   - timelineId: The unique identifier for the chat session.
    ///   - message: The user's input message.
    ///   - tools: Pre-resolved tools available for this turn.
    ///   - toolOutputs: Optional list of tool outputs submitted from a previous externally executed turn.
    ///   - turnBriefingBuilder: Optional turn briefing builder for RAG. If nil, no context is gathered.
    ///   - systemInstructions: Optional system instructions to override the default.
    ///   - agentInstanceId: Optional identifier for the agent instance.
    ///   - maxTurns: Maximum number of LLM turns before stopping. Defaults to 5.
    /// - Returns: An asynchronous stream of chat events.
    func execute(
        timelineId: UUID,
        sendId: UUID? = nil,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        turnBriefingBuilder: TurnBriefingBuilder? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = Constants.defaultMaxTurns,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyRoundTrip,
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let sid = timelineId.uuidString.prefix(8).lowercased()
        logger.info("Starting chat stream for timeline \(sid)")

        let agentPreflight = try await preflightAgent(id: agentInstanceId)
        guard await dependencies.llmService.isConfigured else { throw ChatEngineError.llmServiceNotConfigured }
        guard structuredOutput == nil || sidecars.isEmpty else {
            throw SidecarError.conflictsWithExplicitStructuredOutput
        }
        try SidecarSchemaComposer.validate(sidecars)

        let context = try await prepareSession(
            timelineId: timelineId,
            sendId: sendId ?? UUID(),
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            turnBriefingBuilder: turnBriefingBuilder,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            agentInstance: agentPreflight.instance,
            agentDiagnostics: agentPreflight.diagnostics,
            maxTurns: maxTurns,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            contextPipeline: contextPipeline,
            assemblyLogger: assemblyLogger
        )

        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let sendID = context.sendId

        let task = Task {
            await runChatLoop(continuation: continuation, context: context)
            await dependencies.timelineManager.removeTask(sendID: sendID, for: timelineId)
        }
        await dependencies.timelineManager.registerTask(task, sendID: sendID, for: timelineId)
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }
}
