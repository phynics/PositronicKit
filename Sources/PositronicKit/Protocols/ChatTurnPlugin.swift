import Foundation
import PKShared
import PKUtilities

// MARK: - CompletedTurn

/// Read-only snapshot of a completed chat turn. Plugins drive the loop by the messages
/// they return from `afterTurn`, not by mutating this snapshot.
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

/// Complete-time turn hook: invoked after each turn completes (LLM response + all tool
/// calls resolved), with the turn's output (`CompletedTurn`). Return messages to inject
/// and trigger a follow-up turn; return `[]` to let the loop end.
///
/// This is the read-write counterpart to `PromptInspecting`. The two hooks fire in different
/// phases and must not merge:
/// - `ChatTurnPlugin.afterTurn` fires post-LLM with the full response, returns `[LLMMessage]`
///   to drive a follow-up turn, and is an ordered `chatTurnPlugins` list.
/// - `PromptInspecting.didComposePrompt` fires at prompt-assembly time (pre-response), returns
///   `Void`, and is a single optional `promptInspector`.
/// Their payloads overlap only on correlation keys; the substantive data is disjoint
/// (output vs. input snapshot). See `PromptInspecting`.
public protocol ChatTurnPlugin: Sendable {
    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage]
}
