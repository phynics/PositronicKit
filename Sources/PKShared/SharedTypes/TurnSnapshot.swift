import Foundation

/// Record of a tool call made during a chat exchange
public struct ToolCallRecord: Codable, Sendable, Equatable {
    public let name: String
    public let arguments: String // raw JSON string
    public let turn: Int

    public init(name: String, arguments: String, turn: Int) {
        self.name = name
        self.arguments = arguments
        self.turn = turn
    }
}

/// Record of a tool execution result
public struct ToolResultRecord: Codable, Sendable, Equatable {
    public let toolCallID: String
    public let name: String
    public let output: String // truncated if very large
    public let turn: Int

    public init(toolCallID: String, name: String, output: String, turn: Int) {
        self.toolCallID = toolCallID
        self.name = name
        self.output = output
        self.turn = turn
    }

    /// Creates a tool-result record using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(toolCallID:name:output:turn:).")
    public init(toolCallId: String, name: String, output: String, turn: Int) {
        self.init(toolCallID: toolCallId, name: name, output: output, turn: turn)
    }

    /// The tool-call identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "toolCallID")
    public var toolCallId: String { toolCallID }

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case name, output, turn
    }
}

/// Non-binary generated-audio metadata retained in a diagnostic turn snapshot.
public struct AudioOutputSnapshot: Codable, Sendable, Equatable {
    public let format: AudioFormat
    public let byteCount: Int
    public let transcript: String

    public init(format: AudioFormat, byteCount: Int, transcript: String) {
        self.format = format
        self.byteCount = byteCount
        self.transcript = transcript
    }
}

/// A serializable snapshot of a complete chat turn, capturing context provenance,
/// LLM inputs/outputs, tool activity, and performance metrics.
///
/// Replaces the former `DebugSnapshot` with richer data derived from `ChatTurnContext`.
/// Persisted as JSON on each assistant message for audit and replay.
public struct TurnSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let timelineID: UUID
    public let agentInstanceID: UUID?
    public let modelName: String
    public let turnCount: Int
    public let maxTurns: Int
    public let systemInstructions: String?

    /// Context sources used in this turn
    public let contextSnapshot: TurnContextSnapshot?

    /// Tool metadata (tool objects aren't Codable, so we store IDs)
    public let availableToolIDs: [String]

    // LLM outputs
    public let fullResponse: String
    public let fullThinking: String
    public let audioOutput: AudioOutputSnapshot?

    // Tool activity
    public let toolCalls: [ToolCallRecord]
    public let toolResults: [ToolResultRecord]

    // Metrics
    public let turnDuration: TimeInterval
    public let tokensPerSecond: Double?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let cachedTokens: Int?

    public init(
        timestamp: Date = Date(),
        timelineID: UUID,
        agentInstanceID: UUID? = nil,
        modelName: String,
        turnCount: Int,
        maxTurns: Int,
        systemInstructions: String? = nil,
        contextSnapshot: TurnContextSnapshot? = nil,
        availableToolIDs: [String] = [],
        fullResponse: String = "",
        fullThinking: String = "",
        audioOutput: AudioOutputSnapshot? = nil,
        toolCalls: [ToolCallRecord] = [],
        toolResults: [ToolResultRecord] = [],
        turnDuration: TimeInterval = 0,
        tokensPerSecond: Double? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedTokens: Int? = nil
    ) {
        self.timestamp = timestamp
        self.timelineID = timelineID
        self.agentInstanceID = agentInstanceID
        self.modelName = modelName
        self.turnCount = turnCount
        self.maxTurns = maxTurns
        self.systemInstructions = systemInstructions
        self.contextSnapshot = contextSnapshot
        self.availableToolIDs = availableToolIDs
        self.fullResponse = fullResponse
        self.fullThinking = fullThinking
        self.audioOutput = audioOutput
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.turnDuration = turnDuration
        self.tokensPerSecond = tokensPerSecond
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
    }

    /// Creates a turn snapshot using the legacy identifier spellings.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use init(..., timelineID:agentInstanceID:...availableToolIDs:...).")
    public init(
        timestamp: Date = Date(),
        timelineId: UUID,
        agentInstanceId: UUID? = nil,
        modelName: String,
        turnCount: Int,
        maxTurns: Int,
        systemInstructions: String? = nil,
        contextSnapshot: TurnContextSnapshot? = nil,
        availableToolIds: [String] = [],
        fullResponse: String = "",
        fullThinking: String = "",
        audioOutput: AudioOutputSnapshot? = nil,
        toolCalls: [ToolCallRecord] = [],
        toolResults: [ToolResultRecord] = [],
        turnDuration: TimeInterval = 0,
        tokensPerSecond: Double? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedTokens: Int? = nil
    ) {
        self.init(
            timestamp: timestamp,
            timelineID: timelineId,
            agentInstanceID: agentInstanceId,
            modelName: modelName,
            turnCount: turnCount,
            maxTurns: maxTurns,
            systemInstructions: systemInstructions,
            contextSnapshot: contextSnapshot,
            availableToolIDs: availableToolIds,
            fullResponse: fullResponse,
            fullThinking: fullThinking,
            audioOutput: audioOutput,
            toolCalls: toolCalls,
            toolResults: toolResults,
            turnDuration: turnDuration,
            tokensPerSecond: tokensPerSecond,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cachedTokens: cachedTokens
        )
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "timelineID")
    public var timelineId: UUID { timelineID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? { agentInstanceID }

    /// Available tool identifiers using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "availableToolIDs")
    public var availableToolIds: [String] { availableToolIDs }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case timelineID = "timelineId"
        case agentInstanceID = "agentInstanceId"
        case modelName, turnCount, maxTurns, systemInstructions, contextSnapshot
        case availableToolIDs = "availableToolIds"
        case fullResponse, fullThinking, audioOutput, toolCalls, toolResults, turnDuration, tokensPerSecond
        case promptTokens, completionTokens, totalTokens, cachedTokens
    }
}
