import Foundation
import PKPrompt
import PKContracts
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
