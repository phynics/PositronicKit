import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Errors thrown by `ChatEngine` during setup and execution.
enum ChatEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput
    case streamTimedOut(TimeInterval)
    case danglingToolCall(id: String)
    case danglingToolResult(id: String)

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
        }
    }

    var remediation: String? {
        switch self {
        case .danglingToolCall, .danglingToolResult:
            return "Repair the persisted conversation history so assistant tool calls and tool results are paired before retrying."
        case .llmServiceNotConfigured, .missingInput, .streamTimedOut:
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

/// Unified runtime turn orchestrator for both interactive chat and autonomous execution.
/// Returns `AsyncThrowingStream<ChatEvent>` for all use cases — callers decide how to consume.
///
/// `ChatEngine` is a thin coordinator: it validates preconditions, delegates session
/// preparation to `TurnPreparer`, and hands the prepared context to `TurnLoopController`
/// which owns the ReAct loop. Prompt follow-up synthesis (`PromptSnapshotBuilder`) and
/// partial-assistant persistence (`PartialAssistantPersistence`) are delegated to focused
/// modules behind this seam.
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
        /// Utility seam used solely by `TurnPreparer.fetchContext` to generate RAG tags
        /// (`generateTags`). Kept separate from `llmService` so the streaming seam stays
        /// narrow; the facade and tests pass the same object for both (PKARCH-004 tension).
        let utilityClient: any LLMUtilityClient
        let toolRouter: ToolRouter
        let chatTurnPlugins: [any ChatTurnPlugin]
        let turnInspector: (any TurnInspecting)?
        let promptHistoryRegistry: TimelinePromptHistoryRegistry
        let streamTimeout: TimeInterval

        init(
            timelineManager: TimelineManager,
            agentInstanceStore: any AgentInstanceStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            messageStore: any MessageStoreProtocol,
            llmService: any LLMStreamClient & LLMUtilityClient,
            toolRouter: ToolRouter,
            chatTurnPlugins: [any ChatTurnPlugin],
            turnInspector: (any TurnInspecting)? = nil,
            promptHistoryRegistry: TimelinePromptHistoryRegistry? = nil,
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
            self.turnInspector = turnInspector
            self.promptHistoryRegistry = promptHistoryRegistry ?? TimelinePromptHistoryRegistry()
            self.streamTimeout = streamTimeout
        }
    }

    // MARK: - Constants

    enum Constants {
        static let sentinelToolName = "tool_call"
        static let defaultMaxTurns = 5
        static let maxRemoteDepth = 3
    }

    let dependencies: Dependencies

    let logger = Logger.module(named: "chat-engine")

    var additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []

    // MARK: - API

    /// Execute a chat turn and return a stream of deltas.
    /// - Parameters:
    ///   - timelineId: The unique identifier for the chat session.
    ///   - message: The user's input message.
    ///   - tools: Pre-resolved tools available for this turn.
    ///   - toolOutputs: Optional list of tool outputs submitted from a previous externally executed turn.
    ///   - contextManager: Optional context manager for RAG. If nil, no context is gathered.
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
        contextManager: ContextManager? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = Constants.defaultMaxTurns,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let sid = ANSIColors.colorize(timelineId.uuidString.prefix(8).lowercased(), color: ANSIColors.brightBlue)
        logger.info("Starting chat stream for timeline \(sid)")

        guard await dependencies.llmService.isConfigured else { throw ChatEngineError.llmServiceNotConfigured }
        guard structuredOutput == nil || sidecars.isEmpty else {
            throw SidecarError.conflictsWithExplicitStructuredOutput
        }
        try SidecarSchemaComposer.validate(sidecars)

        let context = try await TurnPreparer(
            dependencies: dependencies
        ).prepareSession(
            timelineId: timelineId,
            sendId: sendId ?? UUID(),
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            contextManager: contextManager,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            contextPipeline: contextPipeline,
            assemblyLogger: assemblyLogger
        )

        let snapshotBuilder = PromptSnapshotBuilder()
        let partialPersistence = PartialAssistantPersistence(
            messageStore: dependencies.messageStore
        )
        let loopController = TurnLoopController(
            dependencies: dependencies,
            additionalStages: additionalStages,
            snapshotBuilder: snapshotBuilder,
            partialPersistence: partialPersistence
        )

        return AsyncThrowingStream<ChatEvent, Error> { continuation in
            let task = Task {
                await loopController.runChatLoop(continuation: continuation, context: context)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
