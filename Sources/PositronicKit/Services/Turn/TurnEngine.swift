import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Errors thrown by `TurnEngine` during setup and execution.
enum TurnEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput
    case streamTimedOut(TimeInterval)
    case danglingToolCall(id: String)
    case danglingToolResult(id: String)
    case duplicateRequestID(UUID)
    case promptHistoryInconsistent(String)

    var errorDomain: String {
        PKErrorDomain.turn
    }

    var errorCode: Int {
        switch self {
        case .llmServiceNotConfigured: return 9001
        case .missingInput: return 9002
        case .streamTimedOut: return 9003
        case .danglingToolCall: return 9004
        case .danglingToolResult: return 9005
        case .duplicateRequestID: return 9006
        case .promptHistoryInconsistent: return 9007
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .llmServiceNotConfigured:
            return "The LLM service is not configured. Please set up your API endpoint and key."
        case .missingInput:
            return "A message or tool outputs must be provided to start a turn."
        case let .streamTimedOut(timeout):
            return "The model stream did not finish within \(Self.timeoutDescription(timeout)). Please try again."
        case let .danglingToolCall(id):
            return "Thread history contains an assistant tool call with id '\(id)' that has no matching tool result."
        case let .danglingToolResult(id):
            return "Thread history contains a tool result with id '\(id)' that has no matching assistant tool call."
        case let .duplicateRequestID(requestId):
            return "Turn \(requestId.uuidString.prefix(8)) has already been processed. Use a new requestId to start a new turn."
        case let .promptHistoryInconsistent(detail):
            return "The prompt history could not record this turn safely: \(detail)"
        }
    }

    var remediation: String? {
        switch self {
        case .danglingToolCall, .danglingToolResult:
            return "Repair the persisted thread history so assistant tool calls and tool results are paired before retrying."
        case .duplicateRequestID:
            return "The previous turn with this requestId completed successfully. Use a new requestId for a new turn, or if the previous attempt failed it is safe to retry with the same requestId."
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

    var errorDomain: String { PKErrorDomain.turn }
    var errorCode: Int { 9010 }
    var userFriendlyMessage: String {
        "Required \(diagnostic.dependency.rawValue) dependency failed during turn preparation: \(diagnostic.message)"
    }
}

/// Unified runtime turn orchestrator for both interactive chat and autonomous execution.
/// Returns `AsyncThrowingStream<TurnEvent>` for all use cases — callers decide how to consume.
///
/// `TurnEngine` is a thin coordinator: it validates preconditions, prepares the session
/// (context gathering, prompt assembly, prompt-history recording), and drives the ReAct
/// loop. Prompt follow-up synthesis (`PromptSnapshotBuilder`) and partial-assistant
/// persistence (`PartialAssistantPersistence`) remain delegated to focused standalone
/// helpers. Session preparation lives in `TurnEngine+TurnPreparation.swift`; the ReAct
/// loop lives in `TurnEngine+TurnLoop.swift`.
///
/// It is deliberately *not* the public customization surface for downstream applications;
/// external callers are expected to integrate through `PositronicKit` and the higher-level
/// extension protocols rather than depending on this concrete orchestrator directly.
struct TurnEngine {
    struct Dependencies {
        /// Production default for the per-stream idle watchdog. Callers must pass an explicit
        /// bounded value through `Dependencies` when they need to override it.
        static let defaultStreamTimeout: TimeInterval = 60

        let threadManager: ThreadManager
        let agentStore: any AgentStoreProtocol
        let requestOriginStore: any RequestOriginStoreProtocol
        let messageStore: any ThreadMessageStoreProtocol
        let runtimeRepository: (any ThreadRuntimeRepository)?
        let threadAuthorityCoordinator: ThreadAuthorityCoordinator
        /// Streaming chat seam: the runtime turn loop, `LLMStreamingStage`, and the
        /// `isConfigured`/`configuration` precondition checks depend only on this.
        let llmService: any LLMStreamClient
        /// Utility seam used solely by `TurnEngine.fetchContext` to generate RAG tags
        /// (`generateTags`). Kept separate from `llmService` so the streaming seam stays
        /// narrow; the facade and tests pass the same object for both (PKARCH-004 tension).
        let utilityClient: any LLMUtilityClient
        let toolRouter: ToolRouter
        let turnPlugins: [any TurnPlugin]
        let promptObserver: (any PromptObserving)?
        let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
        let loggingConfiguration: LoggingConfiguration
        let degradationPolicy: TurnDegradationPolicy
        let promptHistoryRegistry: ThreadPromptJournals
        let streamTimeout: TimeInterval

        init(
            threadManager: ThreadManager,
            agentStore: any AgentStoreProtocol,
            requestOriginStore: any RequestOriginStoreProtocol,
            messageStore: any ThreadMessageStoreProtocol,
            runtimeRepository: (any ThreadRuntimeRepository)? = nil,
            threadAuthorityCoordinator: ThreadAuthorityCoordinator? = nil,
            llmService: any LLMStreamClient & LLMUtilityClient,
            toolRouter: ToolRouter,
            turnPlugins: [any TurnPlugin],
            promptObserver: (any PromptObserving)? = nil,
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
            loggingConfiguration: LoggingConfiguration = .default,
            degradationPolicy: TurnDegradationPolicy = .failRequired,
            promptHistoryRegistry: ThreadPromptJournals? = nil,
            streamTimeout: TimeInterval = Self.defaultStreamTimeout
        ) {
            self.threadManager = threadManager
            self.agentStore = agentStore
            self.requestOriginStore = requestOriginStore
            self.messageStore = messageStore
            self.runtimeRepository = runtimeRepository
            self.threadAuthorityCoordinator = threadAuthorityCoordinator ?? threadManager.threadAuthorityCoordinator
            self.llmService = llmService
            self.utilityClient = llmService
            self.toolRouter = toolRouter
            self.turnPlugins = turnPlugins
            self.promptObserver = promptObserver
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
            self.loggingConfiguration = loggingConfiguration
            self.degradationPolicy = degradationPolicy
            self.promptHistoryRegistry = promptHistoryRegistry ?? ThreadPromptJournals()
            self.streamTimeout = streamTimeout
        }
    }

    // MARK: - Constants

    enum Constants {
        static let sentinelToolName = "tool_call"
        static let defaultMaxModelRounds = 5
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

    let logger = Logger.module(named: "turn-engine")

    var additionalStages: [any PipelineStage<TurnContext, TurnEvent>] = []

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

    /// Execute a turn and return a stream of deltas.
    /// - Parameters:
    ///   - threadID: The unique identifier for the thread.
    ///   - message: The user's input message.
    ///   - tools: Pre-resolved tools available for this turn.
    ///   - toolOutputs: Optional list of tool outputs submitted from a previous externally executed turn.
    ///   - turnBriefingBuilder: Optional turn briefing builder for RAG. If nil, no context is gathered.
    ///   - systemInstructions: Optional system instructions to override the default.
    ///   - agentId: Optional identifier for the agent.
    ///   - maxModelRounds: Maximum number of LLM turns before stopping. Defaults to 5.
    /// - Returns: An asynchronous stream of turn events.
    func execute(
        threadID: UUID,
        requestId: UUID? = nil,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        turnBriefingBuilder: TurnBriefingBuilder? = nil,
        systemInstructions: String? = nil,
        agentId: UUID? = nil,
        maxModelRounds: Int = Constants.defaultMaxModelRounds,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await execute(
            threadID: threadID,
            requestId: requestId,
            messageContent: MessageContent(message),
            tools: tools,
            toolOutputs: toolOutputs,
            turnBriefingBuilder: turnBriefingBuilder,
            systemInstructions: systemInstructions,
            agentId: agentId,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            contextPipeline: contextPipeline,
            assemblyLogger: assemblyLogger
        )
    }

    func execute(
        threadID: UUID,
        requestId: UUID? = nil,
        messageContent: MessageContent,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        turnBriefingBuilder: TurnBriefingBuilder? = nil,
        systemInstructions: String? = nil,
        agentId: UUID? = nil,
        maxModelRounds: Int = Constants.defaultMaxModelRounds,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        contextPipeline: Pipeline<ContextPipelineContext, ContextGatheringEvent>? = nil,
        assemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let sid = threadID.uuidString.prefix(8).lowercased()
        logger.info("Starting generation stream for thread \(sid)")

        let agentPreflight = try await preflightAgent(id: agentId, threadID: threadID)
        guard await dependencies.llmService.isConfigured else { throw TurnEngineError.llmServiceNotConfigured }
        guard structuredOutput == nil || sidecars.isEmpty else {
            throw SidecarError.conflictsWithExplicitStructuredOutput
        }
        try SidecarSchemaComposer.validate(sidecars)

        let prepared = try await prepareSession(
            threadID: threadID,
            turnID: UUID(),
            requestId: requestId ?? UUID(),
            messageContent: messageContent,
            tools: tools,
            toolOutputs: toolOutputs,
            turnBriefingBuilder: turnBriefingBuilder,
            systemInstructions: systemInstructions,
            agentId: agentId,
            agent: agentPreflight.instance,
            agentDiagnostics: agentPreflight.diagnostics,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            contextPipeline: contextPipeline,
            assemblyLogger: assemblyLogger,
            responseModalities: responseModalities,
            audioOutput: audioOutput
        )

        if case let .existing(admission) = prepared {
            return try await replayExistingTurn(admission)
        }
        guard case let .ready(context) = prepared else {
            throw TurnEngineError.promptHistoryInconsistent("Invalid turn preparation result.")
        }

        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let turnID = context.turnID

        let task = Task {
            await runTurnLoop(continuation: continuation, context: context)
            await dependencies.threadManager.removeTask(turnID: turnID, for: threadID)
        }
        await dependencies.threadManager.registerTask(task, turnID: turnID, for: threadID)
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func replayExistingTurn(_ admission: TurnAdmission) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        guard let repository = dependencies.runtimeRepository else {
            throw TurnEngineError.promptHistoryInconsistent("Turn replay requires a runtime repository.")
        }
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let task = Task {
            do {
                var record = admission.turn
                while !record.isTerminal {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard let refreshed = try await repository.fetchTurn(id: record.identity.turnID) else {
                        throw TurnEngineError.promptHistoryInconsistent("Admitted Turn disappeared during replay.")
                    }
                    record = refreshed
                }
                let messages = try await repository.fetchMessages(for: record.threadID)
                if let messageID = record.terminalMessageID,
                   let assistant = messages.first(where: { $0.id == messageID })
                {
                    continuation.yield(.generation(assistant.content))
                    if case .completed = record.outcome {
                        continuation.yield(.generationCompleted(message: assistant.toMessage(), metadata: APIResponseMetadata()))
                    }
                } else if case .completed = record.outcome {
                    continuation.yield(.completedEmpty(finishReason: nil))
                }
                switch record.outcome {
                case let .failed(message):
                    continuation.yield(.error(message))
                case .cancelled:
                    continuation.yield(.generationCancelled())
                case let .interrupted(reason):
                    continuation.yield(.error(reason))
                case .completed, .none:
                    break
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }
}
