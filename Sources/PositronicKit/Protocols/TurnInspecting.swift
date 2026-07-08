import Foundation
import PKPrompt
import PKShared

/// Observability hook for turn composition, invoked once per round-trip with the
/// rendered prompt, sent messages, and journal snapshot.
///
/// Intentional single-customer extension point: the sole production adapter is
/// Yakamoz's `SwiftDataTurnInspector`. The protocol exists so downstream consumers
/// can plug in their own persistence/inspection layer without forking the runtime.
/// Do not generalize without a second adapter.
public protocol TurnInspecting: Sendable {
    func didComposeTurn(_ inspection: TurnInspection) async
}

/// Stable identity for one composed turn within a logical user send.
///
/// `sendId` stays constant across every round-trip produced by the same `ChatEngine.execute`
/// call. `roundTrip` is the zero-based ordinal of that round-trip within the send.
public struct TurnIdentity: Sendable, Hashable, Equatable {
    public let sendId: UUID
    public let roundTrip: Int

    public init(sendId: UUID, roundTrip: Int) {
        self.sendId = sendId
        self.roundTrip = roundTrip
    }
}

public struct TurnInspection: Sendable {
    /// Consumer-facing mapping that groups every round-trip from one logical send.
    public let identity: TurnIdentity
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    /// Back-compat engine counter. This stays monotonic across the conversation and is
    /// still used as the persisted row key for historical rows.
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt
    public let sentMessages: [LLMMessage]
    public let journal: TurnJournalSnapshot
    public let estimatedTokens: Int

    public init(
        identity: TurnIdentity = TurnIdentity(sendId: UUID(), roundTrip: 0),
        timelineId: UUID,
        agentInstanceId: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int
    ) {
        self.identity = identity
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
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
