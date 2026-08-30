import ErrorKit
import Foundation
import Logging
import PKContracts
import PKPrompt
import PKUtilities

/// Errors thrown by `TurnEngine` during setup and execution.
enum TurnEngineError: PKError {
    case llmServiceNotConfigured
    case missingInput
    case streamTimedOut(TimeInterval)
    case danglingToolCall(id: String)
    case danglingToolResult(id: String)
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
        case let .promptHistoryInconsistent(detail):
            return "The prompt history could not record this turn safely: \(detail)"
        }
    }

    var remediation: String? {
        switch self {
        case .danglingToolCall, .danglingToolResult:
            return "Repair the persisted thread history so assistant tool calls and tool results are paired before retrying."
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

    var errorDomain: String {
        PKErrorDomain.turn
    }

    var errorCode: Int {
        9010
    }

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
    struct TurnExecution {
        let turnID: UUID
        let stream: AsyncThrowingStream<TurnEvent, Error>
    }

    struct Dependencies {
        /// Production default for the per-stream idle watchdog. Callers must pass an explicit
        /// bounded value through `Dependencies` when they need to override it.
        static let defaultStreamTimeout: TimeInterval = 60

        let threadManager: ThreadManager
        let agentStore: any AgentStoreProtocol
        let agentContextSource: any AgentContextSource
        let requestOriginStore: any RequestOriginStoreProtocol
        let runtimeRepository: any ThreadRuntimeRepository
        let threadAuthorityCoordinator: ThreadAuthorityCoordinator
        let agentAuthorityCoordinator: AgentAuthorityCoordinator
        /// Streaming chat seam: the runtime turn loop, `LLMStreamingStage`, and the
        /// `isConfigured`/`configuration` precondition checks depend only on this.
        let llmService: any LLMStreamClient
        let toolRouter: ToolRouter
        let turnContextSource: (any TurnContextSource)?
        let agentActivitySink: (any AgentActivitySink)?
        let turnOutcomeSink: (any TurnOutcomeSink)?
        let diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
        let loggingConfiguration: LoggingConfiguration
        let degradationPolicy: TurnDegradationPolicy
        let promptHistoryRegistry: ThreadPromptJournals
        let eventHub: TurnEventHub
        let streamTimeout: TimeInterval

        init(
            threadManager: ThreadManager,
            agentStore: any AgentStoreProtocol,
            agentContextSource: (any AgentContextSource)? = nil,
            requestOriginStore: any RequestOriginStoreProtocol,
            runtimeRepository: any ThreadRuntimeRepository,
            threadAuthorityCoordinator: ThreadAuthorityCoordinator? = nil,
            agentAuthorityCoordinator: AgentAuthorityCoordinator? = nil,
            llmService: any LLMStreamClient,
            toolRouter: ToolRouter,
            turnContextSource: (any TurnContextSource)? = nil,
            agentActivitySink: (any AgentActivitySink)? = nil,
            turnOutcomeSink: (any TurnOutcomeSink)? = nil,
            diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
            loggingConfiguration: LoggingConfiguration = .default,
            degradationPolicy: TurnDegradationPolicy = .failRequired,
            promptHistoryRegistry: ThreadPromptJournals? = nil,
            eventHub: TurnEventHub? = nil,
            streamTimeout: TimeInterval = Self.defaultStreamTimeout
        ) {
            self.threadManager = threadManager
            self.agentStore = agentStore
            self.agentContextSource = agentContextSource ?? IdentityAgentContextSource()
            self.requestOriginStore = requestOriginStore
            self.runtimeRepository = runtimeRepository
            self.threadAuthorityCoordinator = threadAuthorityCoordinator ?? threadManager.threadAuthorityCoordinator
            self.agentAuthorityCoordinator = agentAuthorityCoordinator ?? AgentAuthorityCoordinator()
            self.llmService = llmService
            self.toolRouter = toolRouter
            self.turnContextSource = turnContextSource
            self.agentActivitySink = agentActivitySink
            self.turnOutcomeSink = turnOutcomeSink
            self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
            self.loggingConfiguration = loggingConfiguration
            self.degradationPolicy = degradationPolicy
            self.promptHistoryRegistry = promptHistoryRegistry ?? ThreadPromptJournals()
            self.eventHub = eventHub ?? TurnEventHub()
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
        static let defaultOutputReserve = 4096
        /// Extra tokens withheld from the context window for provider-side framing/overhead
        /// that is neither prompt nor response (e.g. message wrappers, tool-call scaffolding).
        static let providerOverhead = 512
    }

    let dependencies: Dependencies

    let logger = Logger.module(named: "turn-engine")

    var additionalStages: [any PipelineStage<TurnContext, TurnEvent>] = []

    /// Persists a nonfatal customization diagnostic without changing Turn state.
    func appendCustomizationNotice(
        code: TurnNoticeCode,
        turnID: UUID,
        message: String
    ) async {
        await Self.persistCustomizationNotice(
            repository: dependencies.runtimeRepository,
            logger: logger,
            code: code,
            turnID: turnID,
            message: message
        )
    }

    static func persistCustomizationNotice(
        repository: any ThreadRuntimeRepository,
        logger: Logger,
        code: TurnNoticeCode,
        turnID: UUID,
        message: String
    ) async {
        do {
            try await repository.appendNotice(
                turnID: turnID,
                notice: TurnNotice(kind: code.rawValue, message: message)
            )
        } catch {
            logger.error("Unable to persist runtime customization notice: \(error)")
        }
    }

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
    ///   - systemInstructions: Optional system instructions to override the default.
    ///   - agentId: Optional identifier for the agent.
    ///   - maxModelRounds: Maximum number of LLM turns before stopping. Defaults to 5.
    /// - Returns: An asynchronous stream of turn events.
    func execute(
        threadID: UUID,
        requestId: UUID? = nil,
        messageContent: MessageContent,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentId: UUID? = nil,
        executionKind: TurnExecutionKind = .agentManaged,
        contributors: [TurnContributor] = [],
        maxModelRounds: Int = Constants.defaultMaxModelRounds,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        assemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await startExecution(
            threadID: threadID,
            requestId: requestId,
            messageContent: messageContent,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            agentId: agentId,
            executionKind: executionKind,
            contributors: contributors,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            assemblyLogger: assemblyLogger,
            responseModalities: responseModalities,
            audioOutput: audioOutput
        ).stream
    }

    func execute(
        threadID: UUID,
        requestId: UUID? = nil,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentId: UUID? = nil,
        executionKind: TurnExecutionKind = .agentManaged,
        contributors: [TurnContributor] = [],
        maxModelRounds: Int = Constants.defaultMaxModelRounds,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        assemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await execute(
            threadID: threadID,
            requestId: requestId,
            messageContent: MessageContent(message),
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            agentId: agentId,
            executionKind: executionKind,
            contributors: contributors,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            assemblyLogger: assemblyLogger
        )
    }

    func startExecution(
        threadID: UUID,
        requestId: UUID? = nil,
        messageContent: MessageContent,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentId: UUID? = nil,
        executionKind: TurnExecutionKind = .agentManaged,
        contributors: [TurnContributor] = [],
        maxModelRounds: Int = Constants.defaultMaxModelRounds,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        includeSidecarMechanismPreamble: Bool = false,
        assemblyLogger: Logger? = nil,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil
    ) async throws -> TurnExecution {
        let sid = threadID.uuidString.prefix(8).lowercased()
        logger.info("Starting generation stream for thread \(sid)")

        let agentPreflight = try await preflightAgent(id: agentId, threadID: threadID)
        guard await dependencies.llmService.isConfigured else { throw TurnEngineError.llmServiceNotConfigured }
        guard structuredOutput == nil || sidecars.isEmpty else {
            throw SidecarError.conflictsWithExplicitStructuredOutput
        }
        try SidecarSchemaComposer.validate(sidecars)

        let turnID = UUID()
        let prepared = try await prepareSession(
            threadID: threadID,
            turnID: turnID,
            requestId: requestId ?? UUID(),
            messageContent: messageContent,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            agentId: agentId,
            executionKind: executionKind,
            contributors: contributors,
            agent: agentPreflight.instance,
            agentDiagnostics: agentPreflight.diagnostics,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            includeSidecarMechanismPreamble: includeSidecarMechanismPreamble,
            assemblyLogger: assemblyLogger,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            onAdmission: { [eventHub = dependencies.eventHub] in
                await eventHub.begin(turnID: turnID)
            }
        )

        if case let .existing(admission) = prepared {
            let stream: AsyncThrowingStream<TurnEvent, Error>
            switch admission.disposition {
            case .replayed:
                stream = try await replayExistingTurn(admission)
            case .joined, .admitted:
                if let liveStream = await dependencies.eventHub.subscribeIfActive(
                    turnID: admission.turn.identity.turnID
                ) {
                    stream = liveStream
                } else {
                    stream = try await replayExistingTurn(admission)
                }
            }
            return TurnExecution(
                turnID: admission.turn.identity.turnID,
                stream: stream
            )
        }
        guard case let .ready(context) = prepared else {
            throw TurnEngineError.promptHistoryInconsistent("Invalid turn preparation result.")
        }

        let (sourceStream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        // Durable admission starts the live event lane before preparation continues.
        let stream = await dependencies.eventHub.subscribe(turnID: turnID)

        let bridge = Task {
            do {
                for try await event in sourceStream {
                    await dependencies.eventHub.publish(event, turnID: turnID)
                }
                await dependencies.eventHub.finish(turnID: turnID)
            } catch {
                await dependencies.eventHub.finish(turnID: turnID, error: error)
            }
        }

        let (startSignal, startContinuation) = AsyncStream<Bool>.makeStream()
        let task = Task {
            var startIterator = startSignal.makeAsyncIterator()
            guard await startIterator.next() == true else { return }
            await runTurnLoop(continuation: continuation, context: context)
            await dependencies.threadManager.removeTask(turnID: turnID, for: threadID)
            _ = await bridge.value
        }
        let registered = await dependencies.threadManager.registerTask(task, turnID: turnID, for: threadID)
        if !registered {
            task.cancel()
        }
        startContinuation.yield(registered)
        startContinuation.finish()
        if !registered {
            await dependencies.eventHub.finish(
                turnID: turnID,
                error: ThreadRuntimeRepositoryError.threadBusy(threadID: threadID, activeTurnID: turnID)
            )
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return TurnExecution(turnID: turnID, stream: stream)
    }

    private func replayExistingTurn(_ admission: TurnAdmission) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let repository = dependencies.runtimeRepository
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
                // Replay preserves the existing durable-outcome mapping. Recoverable tool-result
                // persistence, model-round exhaustion, and external deferral are represented by
                // ordinary failed/interrupted outcomes, so replay surfaces their error text; the
                // original live persistence path intentionally clean-closes so the caller can
                // retry. A wrapped provider cancellation replays as durable cancellation because
                // wrapper identity is not part of TurnOutcome.
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
