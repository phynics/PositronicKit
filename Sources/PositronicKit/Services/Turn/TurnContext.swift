import Foundation
import PKPrompt
import PKContracts
import PKUtilities

/// Accumulates parts of a streamed tool call.
struct StreamedToolCall {
    var callId: String
    var name: String
    var args: String

    init(callId: String = "", name: String = "", args: String = "") {
        self.callId = callId
        self.name = name
        self.args = args
    }
}

/// Actor-isolated mutable outputs for a single pipeline turn.
/// Each stage writes into this via dedicated mutation methods; reads from outside use `await`.
actor TurnOutputs {
    private(set) var fullResponse: String = ""
    private(set) var fullThinking: String = ""
    private(set) var toolCallAccumulators: [Int: StreamedToolCall] = [:]
    private(set) var streamUsage: LLMTokenUsage?
    private(set) var streamFinishReason: String?
    private(set) var turnDuration: TimeInterval = 0
    private(set) var tokensPerSecond: Double?
    private(set) var sidecarResults: [SidecarResult] = []
    private(set) var audioData = Data()
    private(set) var audioFormat: AudioFormat?
    private(set) var audioTranscript = ""
    private(set) var audioContinuation: AudioContinuationReference?
    /// Set only after the complete assistant message has been accepted by the message store.
    /// This lets failure recovery distinguish a pre-persistence failure from a later stage error.
    private(set) var assistantResponseDurable = false
    /// The normal terminal assistant message is held until `completeTurn` can commit it with the
    /// terminal outcome in the runtime repository.
    private(set) var terminalAssistantMessage: TimelineMessage?
    /// Completion metadata is assembled before the terminal repository transition but is exposed
    /// only by the terminal coordinator after that transition succeeds.
    private(set) var terminalCompletionMetadata: LLMResponse?

    init() {}

    // MARK: - Mutation Methods (internal — only built-in stages should mutate)

    func setStreamUsage(_ usage: LLMTokenUsage) {
        streamUsage = usage
    }

    func setStreamFinishReason(_ finishReason: String?) {
        streamFinishReason = finishReason
    }

    func appendThinking(_ chunk: String) {
        fullThinking += chunk
    }

    func appendResponse(_ chunk: String) {
        fullResponse += chunk
    }

    func appendAudio(_ delta: LLMAudioDelta) throws {
        if let audioFormat, audioFormat != delta.format {
            throw MultimodalContentError.inconsistentAudioFormat(
                expected: audioFormat,
                actual: delta.format
            )
        }
        audioData.append(delta.data)
        audioFormat = delta.format
        if let transcript = delta.transcript { audioTranscript += transcript }
        if let continuation = delta.continuation { audioContinuation = continuation }
    }

    func accumulateToolCall(index: Int, id: String?, name: String?, args: String?) {
        var acc = toolCallAccumulators[index] ?? StreamedToolCall()
        if let id { acc.callId = id }
        if let name { acc.name += name }
        if let args { acc.args += args }
        toolCallAccumulators[index] = acc
    }

    func setToolCallAccumulator(index: Int, id: String, name: String, args: String) {
        toolCallAccumulators[index] = StreamedToolCall(callId: id, name: name, args: args)
    }

    func removeSentinelAndEmptyToolCalls(sentinel: String) {
        toolCallAccumulators = toolCallAccumulators.filter { _, value in
            !value.name.isEmpty && value.name != sentinel
        }
    }

    func setSidecarResults(_ results: [SidecarResult]) {
        sidecarResults = results
    }

    func markAssistantResponseDurable() {
        assistantResponseDurable = true
    }

    func setTerminalAssistantMessage(_ message: TimelineMessage) {
        terminalAssistantMessage = message
    }

    func setTerminalCompletionMetadata(_ metadata: LLMResponse) {
        terminalCompletionMetadata = metadata
    }

    /// Finalizes the turn: computes timing and throughput metrics.
    func finalizeTurn(startTime: Date) {
        turnDuration = Date().timeIntervalSince(startTime)
        let completionTokens = streamUsage?.completionTokens
            ?? TokenEstimator.estimate(text: fullResponse + fullThinking)
        tokensPerSecond = turnDuration > 0 ? Double(completionTokens) / turnDuration : nil
    }
}

/// Immutable snapshot of a single turn as it moves through the pipeline.
/// Mutable stage outputs are stored in `outputs`, a shared actor reference.
struct TurnContext {
    // Turn-loop configuration (constant across model rounds)
    let timelineID: UUID
    let turnID: UUID
    let requestId: UUID
    let agentId: UUID?
    let agentPrivateTimelineID: UUID?
    /// Immutable Agent continuity captured at admission for managed Turns.
    let agentContext: AgentContextSnapshot?
    let contextContributions: [TurnContextContribution]
    let executionKind: TurnExecutionKind
    let contributors: [TurnContributor]
    let modelName: String
    let maxModelRounds: Int
    let systemInstructions: String?
    let availableTools: [AnyTool]
    /// Workspace authority captured at admission; an empty catalog means no workspace exposes tools.
    let workspaceToolCatalog: WorkspaceToolCatalog?
    let remoteDepth: Int
    let generationParameters: GenerationParameters?
    let structuredOutput: StructuredOutputRequest?
    let sidecars: [SidecarDirective]
    let sidecarCommitPolicy: SidecarCommitPolicy
    let diagnostics: [TurnDiagnostic]
    let responseModalities: Set<ResponseModality>
    let audioOutput: AudioOutputOptions?

    /// Shared actor tracking prompt snapshots and append chain growth across turns.
    /// Created once per `prepareTurn()` call and carried through all model rounds in the loop.
    let promptHistory: TimelinePromptHistory?
    let renderedPrompt: RenderedPrompt?
    let promptHistoryUpdate: PromptHistoryUpdate?

    // Per-turn snapshot (changes each iteration)
    let currentMessages: [LLMMessage]
    let modelRoundIndex: Int

    /// Mutable stage outputs shared via actor reference across struct copies.
    let outputs: TurnOutputs

    init(
        timelineID: UUID,
        turnID: UUID = UUID(),
        requestId: UUID = UUID(),
        agentId: UUID?,
        agentPrivateTimelineID: UUID? = nil,
        agentContext: AgentContextSnapshot? = nil,
        contextContributions: [TurnContextContribution] = [],
        executionKind: TurnExecutionKind = .agentManaged,
        contributors: [TurnContributor] = [],
        modelName: String,
        maxModelRounds: Int,
        systemInstructions: String?,
        availableTools: [AnyTool],
        workspaceToolCatalog: WorkspaceToolCatalog? = nil,
        remoteDepth: Int,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyModelRound,
        diagnostics: [TurnDiagnostic] = [],
        promptHistory: TimelinePromptHistory? = nil,
        renderedPrompt: RenderedPrompt? = nil,
        promptHistoryUpdate: PromptHistoryUpdate? = nil,
        currentMessages: [LLMMessage],
        modelRoundIndex: Int,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil,
        outputs: TurnOutputs = TurnOutputs()
    ) {
        self.timelineID = timelineID
        self.turnID = turnID
        self.requestId = requestId
        self.agentId = agentId
        self.agentPrivateTimelineID = agentPrivateTimelineID
        self.agentContext = agentContext
        self.contextContributions = contextContributions
        self.executionKind = executionKind
        self.contributors = contributors
        self.modelName = modelName
        self.maxModelRounds = maxModelRounds
        self.systemInstructions = systemInstructions
        self.availableTools = availableTools
        self.workspaceToolCatalog = workspaceToolCatalog
        self.remoteDepth = remoteDepth
        self.generationParameters = generationParameters
        self.structuredOutput = structuredOutput
        self.sidecars = sidecars
        self.sidecarCommitPolicy = sidecarCommitPolicy
        self.diagnostics = diagnostics
        self.responseModalities = responseModalities
        self.audioOutput = audioOutput
        self.promptHistory = promptHistory
        self.renderedPrompt = renderedPrompt
        self.promptHistoryUpdate = promptHistoryUpdate
        self.currentMessages = currentMessages
        self.modelRoundIndex = modelRoundIndex
        self.outputs = outputs
    }

    /// PKTool parameters derived from availableTools.
    var toolParams: [LLMToolDefinition] {
        availableTools.map { $0.toLLMToolDefinition() }
    }

    /// Creates a new snapshot for the next model round while keeping the same Turn-loop config.
    func forTurn(
        modelRoundIndex: Int,
        messages: [LLMMessage],
        renderedPrompt: RenderedPrompt? = nil,
        promptHistoryUpdate: PromptHistoryUpdate? = nil
    ) -> TurnContext {
        TurnContext(
            timelineID: timelineID,
            turnID: turnID,
            requestId: requestId,
            agentId: agentId,
            agentPrivateTimelineID: agentPrivateTimelineID,
            agentContext: agentContext,
            contextContributions: contextContributions,
            executionKind: executionKind,
            contributors: contributors,
            modelName: modelName,
            maxModelRounds: maxModelRounds,
            systemInstructions: systemInstructions,
            availableTools: availableTools,
            workspaceToolCatalog: workspaceToolCatalog,
            remoteDepth: remoteDepth,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            sidecars: sidecars,
            sidecarCommitPolicy: sidecarCommitPolicy,
            diagnostics: diagnostics,
            promptHistory: promptHistory,
            renderedPrompt: renderedPrompt ?? self.renderedPrompt,
            promptHistoryUpdate: promptHistoryUpdate ?? self.promptHistoryUpdate,
            currentMessages: messages,
            modelRoundIndex: modelRoundIndex,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            outputs: TurnOutputs()
        )
    }
}
