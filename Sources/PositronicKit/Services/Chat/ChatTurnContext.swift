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
    private(set) var debugToolCalls: [ToolCallRecord] = []
    private(set) var debugToolResults: [ToolResultRecord] = []
    private(set) var sidecarResults: [SidecarResult] = []
    private(set) var audioData = Data()
    private(set) var audioFormat: AudioFormat?
    private(set) var audioTranscript = ""
    private(set) var audioContinuation: AudioContinuationReference?
    /// Set only after the complete assistant message has been accepted by the message store.
    /// This lets failure recovery distinguish a pre-persistence failure from a later stage error.
    private(set) var assistantResponseDurable = false

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

    func addDebugToolCall(_ record: ToolCallRecord) {
        debugToolCalls.append(record)
    }

    func addDebugToolResult(_ record: ToolResultRecord) {
        debugToolResults.append(record)
    }

    func setSidecarResults(_ results: [SidecarResult]) {
        sidecarResults = results
    }

    func markAssistantResponseDurable() {
        assistantResponseDurable = true
    }

    /// Finalizes the turn: computes timing and throughput metrics.
    func finalizeTurn(startTime: Date) {
        turnDuration = Date().timeIntervalSince(startTime)
        let completionTokens = streamUsage?.completionTokens
            ?? TokenEstimator.estimate(text: fullResponse + fullThinking)
        tokensPerSecond = turnDuration > 0 ? Double(completionTokens) / turnDuration : nil
    }
}

/// Immutable snapshot of a single chat turn as it moves through the pipeline.
/// Mutable stage outputs are stored in `outputs`, a shared actor reference.
struct ChatTurnContext {
    // Session-level configuration (constant across turns)
    let threadID: UUID
    let sendId: UUID
    let agentInstanceId: UUID?
    let modelName: String
    let maxTurns: Int
    let systemInstructions: String?
    let availableTools: [AnyTool]
    let contextData: ContextData
    let remoteDepth: Int
    let generationParameters: GenerationParameters?
    let structuredOutput: StructuredOutputRequest?
    let sidecars: [SidecarDirective]
    let sidecarCommitPolicy: SidecarCommitPolicy
    let diagnostics: [TurnDiagnostic]
    let responseModalities: Set<ResponseModality>
    let audioOutput: AudioOutputOptions?

    /// Shared actor tracking prompt snapshots and append chain growth across turns.
    /// Created once per `prepareSession()` call and threaded through all turns in the loop.
    let promptHistory: ThreadPromptHistory?
    let renderedPrompt: RenderedPrompt?
    let promptHistoryUpdate: PromptHistoryUpdate?

    // Per-turn snapshot (changes each iteration)
    let currentMessages: [LLMMessage]
    let turnCount: Int

    /// Mutable stage outputs shared via actor reference across struct copies.
    let outputs: TurnOutputs

    init(
        threadID: UUID,
        sendId: UUID = UUID(),
        agentInstanceId: UUID?,
        modelName: String,
        maxTurns: Int,
        systemInstructions: String?,
        availableTools: [AnyTool],
        contextData: ContextData,
        remoteDepth: Int,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        sidecars: [SidecarDirective] = [],
        sidecarCommitPolicy: SidecarCommitPolicy = .everyRoundTrip,
        diagnostics: [TurnDiagnostic] = [],
        promptHistory: ThreadPromptHistory? = nil,
        renderedPrompt: RenderedPrompt? = nil,
        promptHistoryUpdate: PromptHistoryUpdate? = nil,
        currentMessages: [LLMMessage],
        turnCount: Int,
        responseModalities: Set<ResponseModality> = [.text],
        audioOutput: AudioOutputOptions? = nil,
        outputs: TurnOutputs = TurnOutputs()
    ) {
        self.threadID = threadID
        self.sendId = sendId
        self.agentInstanceId = agentInstanceId
        self.modelName = modelName
        self.maxTurns = maxTurns
        self.systemInstructions = systemInstructions
        self.availableTools = availableTools
        self.contextData = contextData
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
        self.turnCount = turnCount
        self.outputs = outputs
    }

    /// Tool parameters derived from availableTools.
    var toolParams: [LLMToolDefinition] {
        availableTools.map { $0.toLLMToolDefinition() }
    }

    /// Creates a new snapshot for the next turn while keeping the same session config.
    func forTurn(
        turnCount: Int,
        messages: [LLMMessage],
        renderedPrompt: RenderedPrompt? = nil,
        promptHistoryUpdate: PromptHistoryUpdate? = nil
    ) -> ChatTurnContext {
        ChatTurnContext(
            threadID: threadID,
            sendId: sendId,
            agentInstanceId: agentInstanceId,
            modelName: modelName,
            maxTurns: maxTurns,
            systemInstructions: systemInstructions,
            availableTools: availableTools,
            contextData: contextData,
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
            turnCount: turnCount,
            responseModalities: responseModalities,
            audioOutput: audioOutput,
            outputs: TurnOutputs()
        )
    }
}
