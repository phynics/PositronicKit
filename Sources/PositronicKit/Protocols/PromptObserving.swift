import Foundation
import PKPrompt
import PKShared
import PKUtilities

/// Compose-time observability hook: invoked once per round-trip *before* the LLM runs,
/// with the rendered prompt, sent messages, and prompt-journal snapshot — i.e. the input
/// side of the turn, before any response exists.
///
/// This is the read-only counterpart to `ChatTurnPlugin`. The two hooks fire in different
/// phases and must not merge:
/// - `PromptObserving.didComposePrompt` fires at prompt-assembly time (no response yet),
///   returns `Void`, and is a single optional `promptObserver`.
/// - `ChatTurnPlugin.afterTurn` fires after the turn completes (with the full response),
///   returns `[LLMMessage]` to drive a follow-up turn, and is an ordered `chatTurnPlugins`
///   list.
/// Their payloads overlap only on correlation keys (timeline/agent/turn ordinal); the
/// substantive data is disjoint (input snapshot vs. output). See `ChatTurnPlugin`.
///
/// Intentional single-customer extension point: the sole production adapter is
/// Yakamoz's `SwiftDataPromptInspector`. The protocol exists so downstream consumers
/// can plug in their own persistence/inspection layer without forking the runtime.
/// "Do not generalize without a second adapter" applies to *this* protocol's surface
/// (don't broaden `PromptInspection` or add methods without a second real conformer) —
/// it is not a reason to merge with `ChatTurnPlugin`.
public protocol PromptObserving: Sendable {
    func didComposePrompt(_ inspection: PromptInspection) async
}

public struct PromptInspection: Sendable {
    /// Consumer-facing mapping that groups every round-trip from one logical send.
    public let identity: TurnIdentity
    public let threadID: UUID
    public let agentInstanceID: UUID?
    /// Back-compat engine counter. This stays monotonic across the conversation and is
    /// still used as the persisted row key for historical rows.
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt
    public let sentMessages: [LLMMessage]
    public let journal: TurnJournalSnapshot
    public let estimatedTokens: Int

    public init(
        identity: TurnIdentity = TurnIdentity(sendID: UUID(), roundTrip: 0),
        threadID: UUID,
        agentInstanceID: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int
    ) {
        self.identity = identity
        self.threadID = threadID
        self.agentInstanceID = agentInstanceID
        self.turnIndex = turnIndex
        self.model = model
        self.rendered = rendered
        self.sentMessages = sentMessages
        self.journal = journal
        self.estimatedTokens = estimatedTokens
    }

    /// Creates a prompt inspection using the deprecated v3 identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        identity: TurnIdentity = TurnIdentity(sendID: UUID(), roundTrip: 0),
        timelineID: UUID,
        agentInstanceID: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int
    ) {
        self.init(
            identity: identity,
            threadID: timelineID,
            agentInstanceID: agentInstanceID,
            turnIndex: turnIndex,
            model: model,
            rendered: rendered,
            sentMessages: sentMessages,
            journal: journal,
            estimatedTokens: estimatedTokens
        )
    }

    /// Creates a prompt inspection using the deprecated lower-camel v3 spellings.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        identity: TurnIdentity = TurnIdentity(sendID: UUID(), roundTrip: 0),
        timelineId: UUID,
        agentInstanceId: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int
    ) {
        self.init(
            identity: identity,
            threadID: timelineId,
            agentInstanceID: agentInstanceId,
            turnIndex: turnIndex,
            model: model,
            rendered: rendered,
            sentMessages: sentMessages,
            journal: journal,
            estimatedTokens: estimatedTokens
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

public struct TurnJournalSnapshot: Sendable {
    public let overlay: PromptJournalDiff
    public let stablePrefixCount: Int
    public let didCompact: Bool

    public init(overlay: PromptJournalDiff, stablePrefixCount: Int, didCompact: Bool) {
        self.overlay = overlay
        self.stablePrefixCount = stablePrefixCount
        self.didCompact = didCompact
    }
}
