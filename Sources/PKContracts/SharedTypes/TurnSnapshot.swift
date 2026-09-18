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

/// A serializable snapshot of a complete turn, capturing context provenance,
/// LLM inputs/outputs, tool activity, and performance metrics.
///
/// Replaces the former `DebugSnapshot` with richer data derived from `TurnContext`.
/// Persisted as JSON on each assistant message for audit and replay.
public struct TurnSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let timelineID: UUID
    public let agentID: UUID?
    public let modelName: String
    public let modelRoundIndex: Int
    public let maxModelRounds: Int
    public let systemInstructions: String?

    /// Context sources used in this turn
    public let contextSnapshot: TurnContextSnapshot?

    /// PKTool metadata (tool objects aren't Codable, so we store IDs)
    public let availableToolIDs: [String]

    // LLM outputs
    public let fullResponse: String
    public let fullThinking: String
    public let audioOutput: AudioOutputSnapshot?

    // PKTool activity
    public let toolCalls: [ToolCallRecord]
    public let toolResults: [ToolResultRecord]

    // Metrics
    public let turnDuration: TimeInterval
    public let tokensPerSecond: Double?
    public let usage: LLMTokenUsage?

    public init(
        timestamp: Date = Date(),
        timelineID: UUID,
        agentID: UUID? = nil,
        modelName: String,
        modelRoundIndex: Int,
        maxModelRounds: Int,
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
        usage: LLMTokenUsage? = nil
    ) {
        self.timestamp = timestamp
        self.timelineID = timelineID
        self.agentID = agentID
        self.modelName = modelName
        self.modelRoundIndex = modelRoundIndex
        self.maxModelRounds = maxModelRounds
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
        self.usage = usage
    }


    private enum CodingKeys: String, CodingKey {
        case timestamp
        case timelineID = "threadId"
        case agentID = "agentId"
        case modelName, modelRoundIndex, maxModelRounds, systemInstructions, contextSnapshot
        case availableToolIDs = "availableToolIds"
        case fullResponse, fullThinking, audioOutput, toolCalls, toolResults, turnDuration, tokensPerSecond
        case usage
    }
}
