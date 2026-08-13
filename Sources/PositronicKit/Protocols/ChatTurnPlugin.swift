import Foundation
import PKShared
import PKUtilities

// MARK: - CompletedTurn

/// Read-only snapshot of a completed chat turn. Plugins drive the loop by the messages
/// they return from `afterTurn`, not by mutating this snapshot.
public struct CompletedTurn: Sendable {
    public let threadID: UUID
    public let agentInstanceID: UUID?
    public let turnCount: Int
    public let fullResponse: String
    public let modelName: String

    public init(
        threadID: UUID,
        agentInstanceID: UUID?,
        turnCount: Int,
        fullResponse: String,
        modelName: String
    ) {
        self.threadID = threadID
        self.agentInstanceID = agentInstanceID
        self.turnCount = turnCount
        self.fullResponse = fullResponse
        self.modelName = modelName
    }

    /// Creates a completed turn using the deprecated v3 identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        timelineID: UUID,
        agentInstanceID: UUID?,
        turnCount: Int,
        fullResponse: String,
        modelName: String
    ) {
        self.init(
            threadID: timelineID,
            agentInstanceID: agentInstanceID,
            turnCount: turnCount,
            fullResponse: fullResponse,
            modelName: modelName
        )
    }

    /// Creates a completed turn using the deprecated lower-camel v3 spellings.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        timelineId: UUID,
        agentInstanceId: UUID?,
        turnCount: Int,
        fullResponse: String,
        modelName: String
    ) {
        self.init(
            threadID: timelineId,
            agentInstanceID: agentInstanceId,
            turnCount: turnCount,
            fullResponse: fullResponse,
            modelName: modelName
        )
    }

    /// The thread identifier using the deprecated v3 spelling.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineID: UUID { threadID }

    /// The thread identifier using the deprecated lower-camel v3 spelling.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineId: UUID { threadID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? { agentInstanceID }
}

// MARK: - ChatTurnPlugin

/// Complete-time turn hook: invoked after each turn completes (LLM response + all tool
/// calls resolved), with the turn's output (`CompletedTurn`). Return messages to inject
/// and trigger a follow-up turn; return `[]` to let the loop end.
///
/// This is the read-write counterpart to `PromptObserving`. The two hooks fire in different
/// phases and must not merge:
/// - `ChatTurnPlugin.afterTurn` fires post-LLM with the full response, returns `[LLMMessage]`
///   to drive a follow-up turn, and is an ordered `chatTurnPlugins` list.
/// - `PromptObserving.didComposePrompt` fires at prompt-assembly time (pre-response), returns
///   `Void`, and is a single optional `promptObserver`.
/// Their payloads overlap only on correlation keys; the substantive data is disjoint
/// (output vs. input snapshot). See `PromptObserving`.
public protocol ChatTurnPlugin: Sendable {
    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage]
}
