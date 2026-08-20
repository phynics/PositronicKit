import Foundation
import PKContracts
import PKUtilities

// MARK: - CompletedTurn

/// Read-only snapshot of a completed turn. Plugins drive the loop by the messages
/// they return from `afterTurn`, not by mutating this snapshot.
public struct CompletedTurn: Sendable {
    public let threadID: UUID
    public let agentID: UUID?
    public let modelRoundIndex: Int
    public let fullResponse: String
    public let modelName: String

    public init(
        threadID: UUID,
        agentID: UUID?,
        modelRoundIndex: Int,
        fullResponse: String,
        modelName: String
    ) {
        self.threadID = threadID
        self.agentID = agentID
        self.modelRoundIndex = modelRoundIndex
        self.fullResponse = fullResponse
        self.modelName = modelName
    }
}

// MARK: - TurnPlugin

/// Complete-time turn hook: invoked after each turn completes (LLM response + all tool
/// calls resolved), with the turn's output (`CompletedTurn`). Return messages to inject
/// and trigger a follow-up turn; return `[]` to let the loop end.
///
/// This is the read-write counterpart to `PromptObserving`. The two hooks fire in different
/// phases and must not merge:
/// - `TurnPlugin.afterTurn` fires post-LLM with the full response, returns `[LLMMessage]`
///   to drive a follow-up turn, and is an ordered `turnPlugins` list.
/// - `PromptObserving.didComposePrompt` fires at prompt-assembly time (pre-response), returns
///   `Void`, and is a single optional `promptObserver`.
/// Their payloads overlap only on correlation keys; the substantive data is disjoint
/// (output vs. input snapshot). See `PromptObserving`.
public protocol TurnPlugin: Sendable {
    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage]
}
