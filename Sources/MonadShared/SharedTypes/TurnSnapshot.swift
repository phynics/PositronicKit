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
    public let toolCallId: String
    public let name: String
    public let output: String // truncated if very large
    public let turn: Int

    public init(toolCallId: String, name: String, output: String, turn: Int) {
        self.toolCallId = toolCallId
        self.name = name
        self.output = output
        self.turn = turn
    }
}

/// A serializable snapshot of a complete chat turn, capturing context provenance,
/// LLM inputs/outputs, tool activity, and performance metrics.
///
/// Replaces the former `DebugSnapshot` with richer data derived from `ChatTurnContext`.
/// Persisted as JSON on each assistant message for audit and replay.
public struct TurnSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let modelName: String
    public let turnCount: Int
    public let maxTurns: Int
    public let systemInstructions: String?

    /// Context sources used in this turn
    public let contextSnapshot: TurnContextSnapshot?

    /// Tool metadata (tool objects aren't Codable, so we store IDs)
    public let availableToolIds: [String]

    // LLM outputs
    public let fullResponse: String
    public let fullThinking: String

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
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        self.modelName = modelName
        self.turnCount = turnCount
        self.maxTurns = maxTurns
        self.systemInstructions = systemInstructions
        self.contextSnapshot = contextSnapshot
        self.availableToolIds = availableToolIds
        self.fullResponse = fullResponse
        self.fullThinking = fullThinking
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.turnDuration = turnDuration
        self.tokensPerSecond = tokensPerSecond
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedTokens = cachedTokens
    }
}
