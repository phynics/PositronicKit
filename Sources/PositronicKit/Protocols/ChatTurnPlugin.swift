import Foundation
import OpenAI

// MARK: - CompletedTurn

/// Read-only snapshot of a completed chat turn.
public struct CompletedTurn: Sendable {
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let turnCount: Int
    public let fullResponse: String
    public let modelName: String

    public init(
        timelineId: UUID,
        agentInstanceId: UUID?,
        turnCount: Int,
        fullResponse: String,
        modelName: String
    ) {
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        self.turnCount = turnCount
        self.fullResponse = fullResponse
        self.modelName = modelName
    }
}

// MARK: - ChatTurnPlugin

/// Called after each complete turn (LLM response + all tool calls resolved).
/// Return messages to inject and trigger a follow-up turn; return [] to let the loop end.
public protocol ChatTurnPlugin: Sendable {
    func afterTurn(_ turn: CompletedTurn) async throws -> [ChatQuery.ChatCompletionMessageParam]
}
